require File.expand_path('../test_helper', File.dirname(__FILE__))

module ActiveRecord
  module ConnectionAdapters
    class BuiltinPoolTest < Test::Unit::TestCase

      include ConnectionAdapters::ConnectionPoolTestMethods

      def config; AR_CONFIG end

      def setup
        super
        @pool = ConnectionPool.new ActiveRecord::Base.connection_pool.spec
      end

      def teardown
        @pool.disconnect!
      end

    end
  end
end