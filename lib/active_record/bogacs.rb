
require 'active_record/bogacs/version'
require 'active_record/bogacs/autoload'

if defined?(Rails::Railtie)
  require 'active_record/bogacs/railtie'
else
  require 'active_record'
  require 'active_record/connection_adapters/pool_class'
end