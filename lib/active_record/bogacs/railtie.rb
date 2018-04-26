module ActiveRecord
  module Bogacs
    class Railtie < Rails::Railtie

      initializer 'active_record.bogacs', :before => 'active_record.initialize_database' do |_|
        ActiveSupport.on_load :active_record do
          require 'active_record/bogacs'

          # support for auto-configuring FalsePool (when config[:pool] set to false) :
          require 'active_record/bogacs/connection_handler'
          ActiveRecord::Base.default_connection_handler = ConnectionHandler.new
        end
      end

    end
  end
end