# coding: utf-8

Gem::Specification.new do |gem|
  gem.name = 'activerecord-bogacs'

  path = File.expand_path('lib/active_record/bogacs/version.rb', File.dirname(__FILE__))
  gem.version = File.read(path).match( /.*VERSION\s*=\s*['"](.*)['"]/m )[1]

  gem.authors = ['Karol Bucek']
  gem.email = ['self@kares.org']
  gem.description = %q{(experimental) alternatives for ActiveRecord::ConnectionAdapters::ConnectionPool}
  gem.summary = %q{A small body of still water, usually fresh ... for ActiveRecord!}
  gem.homepage = "http://github.com/kares/activerecord-bogacs"
  #gem.licenses = ['MIT']

  gem.files = `git ls-files`.split($/)
  gem.executables = gem.files.grep(%r{^bin/}) { |f| File.basename(f) }
  gem.test_files = gem.files.grep(%r{^test/})
  gem.require_paths = ["lib"]

  gem.add_runtime_dependency 'atomic', '~> 1.1'
  gem.add_runtime_dependency 'thread_safe', '~> 0.3'

  gem.add_development_dependency 'rake', '~> 10.3'
  gem.add_development_dependency 'test-unit', '~> 2.5'
end
