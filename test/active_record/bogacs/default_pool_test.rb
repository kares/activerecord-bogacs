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

    end
  end
end