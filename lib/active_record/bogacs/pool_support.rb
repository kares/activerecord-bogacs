#require 'thread_safe'

module ActiveRecord
  module Bogacs
    module PoolSupport

      #def self.included(base)
        #base.send :include, ThreadSafe::Synchronized
      #end

      def new_connection
        Base.send(spec.adapter_method, spec.config)
      end

      def current_connection_id
        # NOTE: possible fiber work-around on JRuby ?!
        Base.connection_id ||= Thread.current.object_id
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

      if ActiveRecord::VERSION::STRING > '4.2'

        def run_checkin_callbacks(conn)
          if conn.respond_to?(:_run_checkin_callbacks)
            conn._run_checkin_callbacks do
              conn.expire
            end
          else
            conn.run_callbacks :checkin do
              conn.expire
            end
          end
        end

        def run_checkout_callbacks(conn)
          if conn.respond_to?(:_run_checkout_callbacks)
            conn._run_checkout_callbacks do
              conn.verify!
            end
          else
            conn.run_callbacks :checkout do
              conn.verify!
            end
          end
        end

      else

        def run_checkin_callbacks(conn)
          conn.run_callbacks :checkin do
            conn.expire
          end
        end

        def run_checkout_callbacks(conn)
          conn.run_callbacks :checkout do
            conn.verify!
          end
        end

      end

    end
  end
end