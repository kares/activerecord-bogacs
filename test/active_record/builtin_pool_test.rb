require File.expand_path('../test_helper', File.dirname(__FILE__))

module ActiveRecord
  module ConnectionAdapters
    class BuiltinPoolTest < Test::Unit::TestCase

      include ConnectionAdapters::ConnectionPoolTestMethods

      def config; AR_CONFIG end

      def setup
        super; require 'active_record/bogacs/pool_support'
        @pool = ConnectionPool.new ActiveRecord::Base.connection_pool.spec
        @pool.extend Bogacs::PoolSupport # aligns API for AR < 4.0
      end

    end
  end
end