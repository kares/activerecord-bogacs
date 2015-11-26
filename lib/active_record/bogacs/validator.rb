begin
  require 'concurrent/executors'
  require 'concurrent/timer_task'
rescue LoadError => e
  warn "activerecord-bogacs' validator feature needs gem 'concurrent-ruby', please install or add it to your Gemfile"
  raise e
end

require 'active_record/connection_adapters/adapter_compat'
require 'active_record/bogacs/thread_safe'

module ActiveRecord
  module Bogacs

    # Every +frequency+ seconds, the reaper will call +reap+ on +pool+.
    # A reaper instantiated with a nil frequency will never reap the
    # connection pool.
    #
    # Configure the frequency by setting "reaping_frequency" in your
    # database yaml file.
    class Validator

      attr_reader :pool, :frequency, :timeout

      # Validator.new(self, spec.config[:validate_frequency]).run
      # @private
      def initialize(pool, frequency = 60, timeout = nil)
        @pool = pool; PoolAdaptor.adapt! pool
        if frequency # validate every 60s by default
          frequency = frequency.to_f
          @frequency = frequency > 0.0 ? frequency : false
        else
          @frequency = nil
        end
        if timeout
          timeout = timeout.to_f
          @timeout = timeout > 0.0 ? timeout : 0
        else
          @timeout = @frequency
        end
        @running = nil
      end

      def run
        return unless frequency
        @running = true; start
      end

      TimerTask = ::Concurrent::TimerTask
      private_constant :TimerTask rescue nil

      def start
        TimerTask.new(:execution_interval => frequency, :timeout_interval => timeout) do
          validate_connections
        end
      end

      def running?; @running end

      def validate
        start = Time.now
        conns = connections
        logger && logger.debug("[validator] found #{conns.size} candidates to validate")
        invalid = 0
        conns.each { |connection| invalid += 1 if validate_connection(connection) == false }
        logger && logger.info("[validator] validated pool in #{Time.now - start}s (removed #{invalid} connections from pool)")
      end

      private

      def connections
        connections = pool.connections.dup
        connections.map! do |conn|
          if conn
            owner = conn.owner
            if conn.in_use?
              if owner && ! owner.alive? # stale-conn (reaping)
                pool.remove conn # remove is synchronized
                conn.disconnect! rescue nil
                nil
              elsif ! owner # NOTE: this is likely a nasty bug
                logger && logger.warn("[validator] found in-use connection without owner - removing from pool")
                pool.remove_without_owner conn
                conn.disconnect! rescue nil
                nil
              else
                nil # owner.alive? ... do not touch
              end
            else
              conn # conn not in-use - candidate for validation
            end
          end
        end
        connections.compact
      end

      def validate_connection(conn)
        return nil if conn.in_use?
        pool.synchronize do # make sure it won't get checked-out while validating
          return nil if conn.in_use?
          # NOTE: active? is assumed to behave e.g. connection_alive_timeout used
          # on AR-JDBC active? might return false as the JDBC connection is lazy
          # ... but that is just fine!
          return true if conn.active? # validate the connection - ping the DB

          # TODO support last_use - only validate if certain amount since use passed

          logger && logger.debug("[validator] found non-active connection - removing from pool")
          pool.remove_without_owner conn # not active - remove
          conn.disconnect! rescue nil
          return false
        end
      end

      #def synchronize(&block); pool.synchronize(&block) end

      def logger
        @logger ||= ( pool.respond_to?(:logger) ? pool.logger : nil ) rescue nil
      end

      module PoolAdaptor

        def self.adapt!(pool)
          unless pool.class.include?(PoolAdaptor)
            pool.class.send :include, PoolAdaptor
          end

          return if pool.respond_to?(:thread_cached_conns)

          if pool.instance_variable_get :@reserved_connections
            class << pool
              attr_reader :reserved_connections
              alias_method :thread_cached_conns, :reserved_connections
            end
          elsif pool.instance_variable_get :@thread_cached_conns
            class << pool
              attr_reader :thread_cached_conns
            end
          else
            raise NotImplementedError, "could not adapt pool: #{pool}"
          end
        end

        def cached_conn_owner_id(conn)
          thread_cached_conns.keys.each do |owner_id|
            if thread_cached_conns[ owner_id ] == conn
              return owner_id
            end
          end
          nil
        end

        def remove_without_owner(conn)
          remove conn # release(conn, nil) owner.object_id should do fine
          release_without_owner conn
        end

        def release_without_owner(conn)
          if owner_id = cached_conn_owner_id(conn)
            thread_cached_conns.delete owner_id; return true
          end
        end

      end

    end

  end
end