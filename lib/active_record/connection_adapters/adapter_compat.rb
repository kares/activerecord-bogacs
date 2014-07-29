require 'active_record/connection_adapters/abstract_adapter'

module ActiveRecord
  module ConnectionAdapters
    AbstractAdapter.class_eval do
      include MonitorMixin

      # NOTE: to initialize the monitor, in 3.2 #initialize calls the
      # MonitorMixin#initialize by doing super() but in 2.3 it does not
      # we do about the same here by overriding Adapter#new :
      # @private
      def self.new(*args)
        instance = super *args
        instance.send :mon_initialize
        instance
      end

      attr_accessor :pool

      attr_reader :last_use, :in_use
      alias :in_use? :in_use

      def lease
        synchronize do
          unless in_use
            @in_use = true
            @last_use = Time.now
          end
        end
      end

      def expire
        @in_use = false
      end

    end
  end
end