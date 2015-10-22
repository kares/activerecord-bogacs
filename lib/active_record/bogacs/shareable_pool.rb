require 'active_record/connection_adapters/abstract/connection_pool'

require 'thread'

require 'active_record/bogacs/thread_safe'

require 'active_record/bogacs/pool_support'

# NOTE: needs explicit configuration - before connection gets established e.g.
#
#   pool_class = ActiveRecord::ConnectionAdapters::ShareableConnectionPool
#   ActiveRecord::ConnectionAdapters::ConnectionHandler.connection_pool_class = pool_class
#
module ActiveRecord
  module Bogacs
    class ShareablePool < ConnectionAdapters::ConnectionPool # NOTE: maybe do not override?!
      include PoolSupport

      if ActiveRecord::Bogacs::ThreadSafe.load_cheap_lockable(false)
        include ThreadSafe::CheapLockable
      else
        alias_method :cheap_synchronize, :synchronize
      end

      ActiveRecord::Bogacs::ThreadSafe.load_atomic_reference
      AtomicReference = ThreadSafe::AtomicReference

      DEFAULT_SHARED_POOL = 0.25 # only allow 25% of the pool size to be shared
      MAX_THREAD_SHARING = 5 # not really a strict limit but should hold

      attr_reader :shared_size

      # @override
      def initialize(spec)
        super(spec) # ConnectionPool#initialize
        shared_size = spec.config[:shared_pool]
        shared_size = shared_size ? shared_size.to_f : DEFAULT_SHARED_POOL
        # size 0.0 - 1.0 assumes percentage of the pool size
        shared_size = ( @size * shared_size ).round if shared_size <= 1.0
        @shared_size = shared_size.to_i
        @shared_connections = ThreadSafe::Map.new # :initial_capacity => @shared_size, :concurrency_level => 20
      end

      # @override
      def connection
        Thread.current[shared_connection_key] || begin # super - simplified :
          super # @reserved_connections.compute_if_absent(current_connection_id) { checkout }
        end
      end

      # @override
      def active_connection?
        if shared_conn = Thread.current[shared_connection_key]
          return shared_conn.in_use?
        end
        super_active_connection? current_connection_id
      end

      # @override called from ConnectionManagement middle-ware (when finished)
      def release_connection(with_id = current_connection_id)
        if reserved_conn = @reserved_connections[with_id]
          if shared_count = @shared_connections[reserved_conn]
            cheap_synchronize do # lock due #get_shared_connection ... not needed ?!
              # NOTE: the other option is to not care about shared here at all ...
              if shared_count.get == 0 # releasing a shared connection
                release_shared_connection(reserved_conn)
              #else return false
              end
            end
          else # check back-in non-shared connections
            checkin reserved_conn # (what super does)
          end
        end
      end

      # @override
      def disconnect!
        cheap_synchronize { @shared_connections.clear; super }
      end

      # @override
      def clear_reloadable_connections!
        cheap_synchronize { @shared_connections.clear; super }
      end

      # @override
      # @note called from #reap thus the pool should work with reaper
      def remove(conn)
        cheap_synchronize { @shared_connections.delete(conn); super }
      end

#      # Return any checked-out connections back to the pool by threads that
#      # are no longer alive.
#      # @private AR 3.2 compatibility
#      def clear_stale_cached_connections!
#        keys = Thread.list.find_all { |t| t.alive? }.map(&:object_id)
#        keys = @reserved_connections.keys - keys
#        keys.each do |key|
#          release_connection(key)
#          @reserved_connections.delete(key)
#        end
#      end if ActiveRecord::VERSION::MAJOR < 4

      # TODO take care of explicit connection.close (`pool.checkin self`) ?

      # Custom API :

      def release_shared_connection(connection)
        shared_conn_key = shared_connection_key
        if connection == Thread.current[shared_conn_key]
          Thread.current[shared_conn_key] = nil
        end

        @shared_connections.delete(connection)
        checkin connection
      end

      def with_shared_connection
        shared_conn_key = shared_connection_key
        # with_shared_connection call nested in the same thread
        if connection = Thread.current[shared_conn_key]
          emulated_checkout(connection)
          return yield connection
        end

        start = Time.now if DEBUG
        begin
          connection_id = current_connection_id
          # if there's a 'regular' connection on the thread use it as super
          if super_active_connection?(connection_id) # for current thread
            connection = self.connection # do not mark as shared
            DEBUG && debug("with_shared_conn 10 got active = #{connection.to_s}")
          # otherwise if we have a shared connection - use that one :
          elsif connection = get_shared_connection
            emulated_checkout(connection); shared = true
            DEBUG && debug("with_shared_conn 20 got shared = #{connection.to_s}")
          else
            cheap_synchronize do
              # check shared again as/if threads end up sync-ing up here :
              if connection = get_shared_connection
                emulated_checkout(connection)
                DEBUG && debug("with_shared_conn 21 got shared = #{connection.to_s}")
              end # here we acquire but a connection from the pool
              # TODO the bottle-neck for concurrency doing sync { checkout } :
              unless connection # here we acquire a connection from the pool
                connection = self.checkout # might block if pool fully used
                add_shared_connection(connection)
                DEBUG && debug("with_shared_conn 30 acq shared = #{connection.to_s}")
              end
            end
            shared = true
          end

          Thread.current[shared_conn_key] = connection if shared

          DEBUG && debug("with_shared_conn obtaining a connection took #{(Time.now - start) * 1000}ms")
          yield connection
        ensure
          Thread.current[shared_conn_key] = nil # if shared
          rem_shared_connection(connection) if shared
        end
      end

      private

      def super_active_connection?(connection_id = current_connection_id)
        (@reserved_connections.get(connection_id) || ( return false )).in_use?
      end

      def super_active_connection?(connection_id = current_connection_id)
        synchronize do
          (@reserved_connections[connection_id] || ( return false )).in_use?
        end
      end if ActiveRecord::VERSION::MAJOR < 4

      def acquire_connection_no_wait?
        synchronize do
          @connections.size < @size || @available.send(:can_remove_no_wait?)
          #return true if @connections.size < @size
          # @connections.size < @size || Queue#can_remove_no_wait? :
          #queue = @available.instance_variable_get(:@queue)
          #num_waiting = @available.instance_variable_get(:@num_waiting)
          #queue.size > num_waiting
        end
      end

      def acquire_connection_no_wait?
        synchronize do
          @connections.size < @size || @connections.any? { |c| ! c.in_use? }
        end
      end if ActiveRecord::VERSION::MAJOR < 4

      # get a (shared) connection that is least shared among threads (or nil)
      # nil gets returned if it's 'better' to checkout a new one to be shared
      # ... to better utilize shared connection reuse among multiple threads
      def get_shared_connection # (lock = nil)
        least_count = MAX_THREAD_SHARING + 1; least_shared = nil
        shared_connections_size = @shared_connections.size

        @shared_connections.each_pair do |connection, shared_count|
          next if shared_count.get >= MAX_THREAD_SHARING
          if ( shared_count = shared_count.get ) < least_count
            DEBUG && debug(" get_shared_conn loop : #{connection.to_s} shared #{shared_count}-time(s)")
            # ! DO NOT return connection if shared_count == 0
            least_count = shared_count; least_shared = connection
          end
        end

        if least_count > 0
          if shared_connections_size < @shared_connections.size
            DEBUG && debug(" get_shared_conn retry (shared connection added)")
            return get_shared_connection # someone else added something re-try
          end
          if ( @shared_connections.size < @shared_size ) && acquire_connection_no_wait?
            DEBUG && debug(" get_shared_conn return none - acquire from pool")
            return nil # we should rather 'get' a new shared one from the pool
          end
        end

        # we did as much as could without a lock - now sync due possible release
        cheap_synchronize do # TODO although this likely might be avoided ...
          # should try again if possibly the same connection got released :
          unless least_count = @shared_connections[least_shared]
            DEBUG && debug(" get_shared_conn retry (connection got released)")
            return get_shared_connection
          end
          least_count.update { |v| v + 1 }
        end if least_shared

        DEBUG && debug(" get_shared_conn least shared = #{least_shared.to_s}")
        least_shared # might be nil in that case we'll likely wait (as super)
      end

      def add_shared_connection(connection)
        @shared_connections[connection] = AtomicReference.new(1)
      end

      def rem_shared_connection(connection)
        if shared_count = @shared_connections[connection]
           # shared_count.update { |v| v - 1 } # NOTE: likely fine without lock!
           cheap_synchronize do # give it back to the pool
             shared_count.update { |v| v - 1 } # might give it back if :
             release_shared_connection(connection) if shared_count.get == 0
           end
        end
      end

      def emulated_checkin(connection)
        # NOTE: not sure we'd like to run `run_callbacks :checkin {}` here ...
        connection.expire
      end

      def emulated_checkout(connection)
        # NOTE: not sure we'd like to run `run_callbacks :checkout {}` here ...
        connection.lease; # connection.verify! auto-reconnect should do this
      end

      def shared_connection_key
        @shared_connection_key ||= :"shared_pool_connection##{object_id}"
      end

      DEBUG = begin
        debug = ENV['DB_POOL_DEBUG'].to_s
        if debug.to_s == 'false' then false
        elsif ! debug.empty?
          log_dev = case debug
          when 'STDOUT', 'stdout' then STDOUT
          when 'STDERR', 'stderr' then STDERR
          when 'true' then ActiveRecord::Base.logger
          else File.expand_path(debug)
          end
          require 'logger'; Logger.new log_dev
        else nil
        end
      end

      private

      def debug(msg); DEBUG.debug msg end

    end
  end
end
