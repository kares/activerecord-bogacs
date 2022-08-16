require 'active_record/connection_adapters/abstract/query_cache'

module ActiveRecord
  module Bogacs
    module PoolSupport

      def self.included(base)
        base.send :include, ActiveRecord::ConnectionAdapters::QueryCache::ConnectionPoolConfiguration
      end if ActiveRecord::ConnectionAdapters::QueryCache.const_defined? :ConnectionPoolConfiguration

      attr_accessor :schema_cache

      def lock_thread=(lock_thread)
        if lock_thread
          @lock_thread = Thread.current
        else
          @lock_thread = nil
        end
      end if ActiveRecord::VERSION::MAJOR > 4

      def new_connection
        conn = Base.send(spec.adapter_method, spec.config)
        conn.schema_cache = schema_cache.dup if schema_cache && conn.respond_to?(:schema_cache=)
        conn
      end

      # @override (previously named current_connection_id)
      # @private connection_cache_key for AR (5.2) compatibility
      def connection_cache_key(owner_thread = Thread.current)
        owner_thread.object_id
      end

      # @note Method not part of the pre 4.0 API (does no exist).
      def remove(conn)
        synchronize do
          @connections.delete conn
          release conn
        end
      end if ActiveRecord::VERSION::MAJOR < 4

      # clear_stale_cached_connections! without the deprecation :
      def reap
        keys = @reserved_connections.keys -
         Thread.list.find_all { |t| t.alive? }.map(&:object_id)
        keys.each do |key|
          conn = @reserved_connections[key]
          checkin conn
          @reserved_connections.delete(key)
        end
      end if ActiveRecord::VERSION::MAJOR < 4

      private

      def current_thread
        @lock_thread || Thread.current
      end

      if ActiveRecord::VERSION::STRING > '4.2'

        def _run_checkin_callbacks(conn)
          if conn.respond_to?(:_run_checkin_callbacks)
            conn._run_checkin_callbacks do
              conn.expire
            end
          else
            conn.run_callbacks :checkin do
              conn.expire
            end
          end
        rescue => e
          remove conn
          conn.disconnect! rescue nil
          raise e
        end

        def _run_checkout_callbacks(conn)
          if conn.respond_to?(:_run_checkout_callbacks)
            conn._run_checkout_callbacks do
              conn.verify!
            end
          else
            conn.run_callbacks :checkout do
              conn.verify!
            end
          end
        rescue => e
          remove conn
          conn.disconnect! rescue nil
          raise e
        end

      else

        def _run_checkin_callbacks(conn)
          conn.run_callbacks :checkin do
            conn.expire
          end
        end

        def _run_checkout_callbacks(conn)
          conn.run_callbacks :checkout do
            conn.verify!
          end
        end

      end

    end
  end
end
