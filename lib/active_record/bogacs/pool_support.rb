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

    end
  end
end