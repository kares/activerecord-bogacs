source 'https://rubygems.org'

gemspec

if version = ENV['AR_VERSION']
  if version.index('/') && ::File.exist?(version)
    gem 'activerecord', :path => version
  elsif version =~ /^[0-9abcdef]+$/
    gem 'activerecord', :github => 'rails/rails', :ref => version
  elsif version.index('.').nil?
    gem 'activerecord', :github => 'rails/rails', :branch => version
  else
    gem 'activerecord', version, :require => nil
  end
else
  gem 'activerecord', :require => nil
end

gem 'activerecord-jdbc-adapter', :require => nil, :platform => :jruby

#gem 'thread_safe', :require => nil # "optional" - we can roll without it

if defined?(JRUBY_VERSION) && JRUBY_VERSION < '1.7.0'
gem 'jruby-openssl', :platform => :jruby
end

group :test do
  gem 'jdbc-mysql', :require => nil, :platform => :jruby
  gem 'jdbc-postgres', :require => nil, :platform => :jruby

  gem 'mysql2', :require => nil, :platform => :mri
  gem 'pg', :require => nil, :platform => :mri
end