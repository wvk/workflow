# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = %q{workflow}
  s.version = "0.7.3"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ['Vladimir Dobriakov', 'Willem van Kerkhof']
  s.date = %q{2010-10-12}
  s.description = %q{    Workflow is a finite-state-machine-inspired API for modeling and interacting
    with what we tend to refer to as 'workflow'.

    * nice DSL to describe your states, events and transitions
    * robust integration with ActiveRecord and non relational data stores
    * various hooks for single transitions, entering state etc.
    * convenient access to the workflow specification: list states, possible events
      for particular state
    * state and transition dependent validations for ActiveModel
}
  s.email = %q{vladimir@geekq.net, wvk@consolving.de}
  s.extra_rdoc_files = ["README.markdown"]
  s.files = [".gitignore", "MIT-LICENSE", "README.markdown", "Rakefile", "VERSION", "lib/workflow.rb", "test/couchtiny_example.rb", "test/main_test.rb", "test/multiple_workflows_test.rb", "test/readme_example.rb", "test/test_helper.rb", "test/without_active_record_test.rb", "workflow.rb"]
  s.homepage = %q{http://www.geekq.net/workflow/}
  s.rdoc_options = ["--charset=UTF-8"]
  s.require_paths = ["lib"]
  s.rubyforge_project = %q{workflow}
  s.rubygems_version = %q{1.3.7}
  s.summary = %q{A replacement for acts_as_state_machine.}
  s.test_files = ["test/couchtiny_example.rb", "test/main_test.rb", "test/test_helper.rb", "test/without_active_record_test.rb", "test/multiple_workflows_test.rb", "test/readme_example.rb"]

  if s.respond_to? :specification_version then
    current_version = Gem::Specification::CURRENT_SPECIFICATION_VERSION
    s.specification_version = 3

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
    else
    end
  else
  end
end
