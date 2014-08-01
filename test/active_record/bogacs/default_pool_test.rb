require File.expand_path('../../test_helper', File.dirname(__FILE__))

ActiveRecord::Bogacs::DefaultPool.class_eval do
  # ...
end

module ActiveRecord
  module Bogacs
    class DefaultPoolTest < Test::Unit::TestCase

      include ConnectionAdapters::ConnectionPoolTestMethods

      def config; AR_CONFIG end

      def setup
        super
        @pool = DefaultPool.new ActiveRecord::Base.connection_pool.spec
      end

      def test_prefills_initial_connections
        @pool.disconnect!
        spec = ActiveRecord::Base.connection_pool.spec.dup
        spec.instance_variable_set :@config, spec.config.merge(:pool_initial => 1.0)
        @pool = DefaultPool.new spec
        assert_equal @pool.size, @pool.connections.size
      end

      def test_does_not_prefill_connections_by_default
        assert_equal 0, @pool.connections.size
      end

    end
  end
end