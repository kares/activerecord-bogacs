#require 'thread_safe'

module ActiveRecord
  module Bogacs
    module PoolSupport

      def self.included(base)
        #base.send :include, ThreadSafe::Util::CheapLockable
      end

      def new_connection
        Base.send(spec.adapter_method, spec.config)
      end

      def current_connection_id
        Base.connection_id ||= Thread.current.object_id # TODO
      end

    end
  end
end