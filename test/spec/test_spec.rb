require_relative "spec_helper"

describe "A PHP application" do

  # it "works with the getting started guide" do
  #   Hatchet::Runner.new("php-getting-started").tap do |app|
  #     app.deploy do
  #     #works
  #     end
  #   end
  # end
  #
  it "checks for bad version" do
    Hatchet::Runner.new("test/fixtures/default", allow_failure: true).tap do |app|
      app.before_deploy do
        File.open("composer.json", "w+") do |f|
          f.write '{"require": {
            "php": "7.badversion"
          }}'
        end
      end
      app.deploy do
        expect(app.output).to include("Invalid semantic version \"7.badversion\"") #EDIT THIS MESSAGE
      end
    end
  end
  #
  # it "have absolute buildpack paths" do
  #   buildpacks = [
  #     :default,
  #     "https://github.com/sharpstone/force_absolute_paths_buildpack"
  #   ]
  #   Hatchet::Runner.new("php-getting-started", buildpacks: buildpacks).deploy do |app|
  #     #deploy works
  #   end
  # end

  it "Uses the cache with Heroku CI" do
    Hatchet::Runner.new("php-getting-started").run_ci do |app|
      expect(test_run.output).to_not include("Restoring cache") #EDIT THIS MESSAGE
      test_run.run_again
      expect(test_run.output).to include("Restoring cache")#EDIT THIS MESSAGE
    end
  end

  #Test upgrading stack invalidates the cache
  it "should not restore cached directories" do
    app = Hatchet::Runner.new("test/fixtures/default", allow_failure: true, stack: "heroku-18").setup!
    app.deploy do |app, heroku|
      app.update_stack("heroku-16")
      run!('git commit --allow-empty -m "heroku-16 migrate"')
      app.push!
      expect(app.output).to include("Cached directories were not restored due to a change in version of node, npm, yarn or stack")
    end
  end

  #Test cache for regular deploys is used on repeated deploys
  it "should not restore cache if the stack did not change" do
    app = Hatchet::Runner.new('test/fixtures/default', stack: "heroku-16").setup!
    app.before_deploy {}
    app.deploy do |app, heroku|
      app.update_stack("heroku-16")
      run!('git commit --allow-empty -m "cedar migrate"')
      app.push!
      expect(app.output).to_not include("Cached directories were not restored due to a change in version of node, npm, yarn or stack")
      expect(app.output).to include("not cached - skipping")
    end
  end
end
