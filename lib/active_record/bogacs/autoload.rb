module ActiveRecord
  module Bogacs
    autoload :DefaultPool, 'active_record/bogacs/default_pool'
    autoload :FalsePool, 'active_record/bogacs/false_pool'
    autoload :ShareablePool, 'active_record/bogacs/shareable_pool'
    autoload :Reaper, 'active_record/bogacs/reaper'
    autoload :Validator, 'active_record/bogacs/validator'
  end
  autoload :SharedConnection, 'active_record/shared_connection'
end