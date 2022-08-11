require 'active_record/version'

require 'concurrent/atomic/atomic_boolean'

require 'active_record/bogacs/pool_support'
require 'active_record/bogacs/thread_safe'

module ActiveRecord
  module Bogacs
    class FalsePool

      include PoolSupport

      include ThreadSafe::Synchronized

      attr_accessor :automatic_reconnect

      attr_reader :size, :spec

      def initialize(spec)
        @spec = spec
        @size = nil
        @automatic_reconnect = nil
        @lock_thread = false

        @thread_cached_conns = ThreadSafe::Map.new

        @connected = ::Concurrent::AtomicBoolean.new
      end

      # @private attr_reader :reaper
      def reaper; end

      # @private
      def checkout_timeout; end

      # Retrieve the connection associated with the current thread, or call
      # #checkout to obtain one if necessary.
      #
      # #connection can be called any number of times; the connection is
      # held in a hash keyed by the thread id.
      def connection
        connection_id = current_connection_id(current_thread)
        @thread_cached_conns[connection_id] ||= checkout
      end

      # Is there an open connection that is being used for the current thread?
      def active_connection?
        connection_id = current_connection_id(current_thread)
        @thread_cached_conns[connection_id]
      end

      # Signal that the thread is finished with the current connection.
      # #release_connection releases the connection-thread association
      # and returns the connection to the pool.
      def release_connection(owner_thread = Thread.current)
        conn = @thread_cached_conns.delete(current_connection_id(owner_thread))
        checkin conn if conn
      end

      # If a connection already exists yield it to the block. If no connection
      # exists checkout a connection, yield it to the block, and checkin the
      # connection when finished.
      def with_connection
        connection_id = current_connection_id
        unless conn = @thread_cached_conns[connection_id]
          conn = connection
          fresh_connection = true
        end
        yield conn
      ensure
        release_connection if fresh_connection
      end

      # Returns true if a connection has already been opened.
      def connected?; @connected.true? end

      # @private replacement for attr_reader :connections
      def connections; @thread_cached_conns.values end

      # Disconnects all connections in the pool, and clears the pool.
      def disconnect!
        synchronize do
          @connected.make_false

          connections = @thread_cached_conns.values
          @thread_cached_conns.clear
          connections.each do |conn|
            if conn.in_use?
              conn.steal!
              checkin conn
            end
            conn.disconnect!
          end
        end
      end

      def discard! # :nodoc:
        synchronize do
          return if @thread_cached_conns.nil? # already discarded
          @connected.make_false

          connections.each do |conn|
            conn.discard!
          end
          @thread_cached_conns = nil
        end
      end

      # Clears the cache which maps classes.
      def clear_reloadable_connections!
        synchronize do
          @connected.make_false

          connections = @thread_cached_conns.values
          @thread_cached_conns.clear

          connections.each do |conn|
            if conn.in_use?
              conn.steal!
              checkin conn
            end
            conn.disconnect! if conn.requires_reloading?
          end
        end
      end

      # Verify active connections and remove and disconnect connections
      # associated with stale threads.
      # @private AR 3.2 compatibility
      def verify_active_connections!
        synchronize do
          clear_stale_cached_connections!
          @thread_cached_conns.values.each(&:verify!)
        end
      end if ActiveRecord::VERSION::MAJOR < 4

      # Return any checked-out connections back to the pool by threads that
      # are no longer alive.
      # @private AR 3.2 compatibility
      def clear_stale_cached_connections!
        keys = Thread.list.find_all { |t| t.alive? }.map { |t| current_connection_id(t) }
        keys = @thread_cached_conns.keys - keys
        keys.each do |key|
          if conn = @thread_cached_conns[key]
            checkin conn, true # no release
            @thread_cached_conns.delete(key)
          end
        end
      end if ActiveRecord::VERSION::MAJOR < 4

      # Check-out a database connection from the pool, indicating that you want
      # to use it. You should call #checkin when you no longer need this.
      #
      # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @raise [ActiveRecord::ConnectionTimeoutError] no connection can be obtained from the pool
      def checkout
        conn = checkout_new_connection # acquire_connection
        synchronize do
          conn.lease
          _run_checkout_callbacks(conn) # checkout_and_verify(conn)
        end
        conn
      end

      # Check-in a database connection back into the pool, indicating that you
      # no longer need this connection.
      #
      # @param conn [ActiveRecord::ConnectionAdapters::AbstractAdapter] connection
      # object, which was obtained earlier by calling #checkout on this pool
      # @see #checkout
      def checkin(conn, released = nil)
        release(conn) unless released
        _run_checkin_callbacks(conn)
      end

      # Remove a connection from the connection pool.  The connection will
      # remain open and active but will no longer be managed by this pool.
      def remove(conn)
        release(conn)
      end

      # @private
      def reap
        # we do not really manage the connection pool - nothing to do ...
      end

      def flush(minimum_idle = nil)
        # we do not really manage the connection pool
      end

      def flush!
        reap
        flush(-1)
      end

      def stat
        {
          connections: connections.size
        }
      end

      private

      # @raise [ActiveRecord::ConnectionTimeoutError]
      def acquire_connection
        # underlying pool will poll and block if "empty" (all checked-out)
        #if conn = @available.poll
          #conn
        #elsif @connections.size < @size
          #checkout_new_connection
        #else
          #reap
          #@available.poll(@checkout_timeout)
        #end
        checkout_new_connection
      end

      def release(conn, owner = conn.owner)
        thread_id = current_connection_id(owner) unless owner.nil?

        thread_id ||=
          if @thread_cached_conns[conn_id = current_connection_id] == conn
            conn_id
          else
            connections = @thread_cached_conns
            connections.keys.find { |k| connections[k] == conn }
          end

        @thread_cached_conns.delete thread_id if thread_id
      end

      def checkout_new_connection
        # NOTE: automatic reconnect seems to make no sense for us!
        #raise ConnectionNotEstablished unless @automatic_reconnect

        begin
          conn = new_connection
        rescue ConnectionTimeoutError => e
          raise e
        rescue => e
          raise ConnectionTimeoutError, e.message if timeout_error?(e)
          raise e
        end
        @connected.make_true
        conn.pool = self
        conn
      end

      #def checkout_and_verify(conn)
      #  conn.run_callbacks(:checkout) { conn.verify! }
      #  conn
      #end

      TIMEOUT_ERROR = /timeout|timed.?out/i

      def timeout_error?(error)
        full_error = error.inspect
        # Tomcat JDBC :
        # ActiveRecord::JDBCError(<The driver encountered an unknown error:
        #   org.apache.tomcat.jdbc.pool.PoolExhaustedException:
        #   [main] Timeout: Pool empty. Unable to fetch a connection in 2 seconds,
        #   none available[size:10; busy:10; idle:0; lastwait:2500].>
        # )
        # C3P0 :
        # java.sql.SQLException: An attempt by a client to checkout a Connection has timed out.
        return true if full_error =~ TIMEOUT_ERROR
        # NOTE: not sure what to do on MRI and friends (C-pools not tested)
        false
      end

      #def timeout_error?(error)
      #  if error.is_a?(JDBCError)
      #    if sql_exception = error.sql_exception
      #      return true if sql_exception.to_s =~ /timeout/i
      #    end
      #  end
      #end if defined? ArJdbc

    end
  end
end
