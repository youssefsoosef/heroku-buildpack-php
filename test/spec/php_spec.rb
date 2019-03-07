require_relative "spec_helper"

describe "A PHP application" do
	def self.genmatrix(matrix, keys = nil)
		product_hash(matrix.select {|k,v| !keys || keys.include?(k) })
	end
	
	def self.gencmd(args)
		args.compact.map { |k,v|
			if k.is_a? Numeric
				ret = v.shellescape # it's an argument, so we want the value only
			else
				ret = k.shellescape
				unless !!v == v # check if boolean
					ret.concat(" #{v.shellescape}") # --foobar flags have no values
				end
			end
			ret
		}.join(" ").strip
	end
	
	# the matrix of options and arguments to test
	# we will generate all possible combinations of these using a helper
	# nil means omitted
	# anything with "broken" in the value will be treated as expected to fail
	matrices = {
		"apache2" => {
			0 => [
				"heroku-php-apache2"
			],
			'-C' => [
				nil,
				"conf/apache2.server.include.conf",
				"conf/apache2.server.include.dynamic.conf.php",
				"conf/apache2.server.include.broken"
			],
			'-F' => [
				nil,
				"conf/fpm.include.conf",
				"conf/fpm.include.dynamic.conf.php",
				"conf/fpm.include.broken"
			],
			1 => [ # document root argument
				nil,
				"docroot/",
				"brokendocroot/"
			]
		},
		"nginx" => {
			0 => [
				"heroku-php-nginx"
			],
			'-C' => [
				nil,
				"conf/nginx.server.include.conf",
				"conf/nginx.server.include.dynamic.conf.php",
				"conf/nginx.server.include.broken"
			],
			'-F' => [
				nil,
				"conf/fpm.include.conf",
				"conf/fpm.include.dynamic.conf.php",
				"conf/fpm.include.broken"
			],
			1 => [ # document root argument
				nil,
				"docroot/",
				"brokendocroot/"
			]
		}
	}
	
	context "with just an index.php" do
		let(:app) {
			Hatchet::Runner.new('test/fixtures/bootopts', stack: ENV["STACK"])
		}
		it "picks a default version from the expected series" do
			app.deploy do |app|
				series = expected_default_php(ENV["STACK"])
				expect(app.output).to match(/- php \(#{Regexp.escape(series)}\./)
				expect(app.run('php -v')).to match(/#{Regexp.escape(series)}\./)
			end
		end
		# FIXME re-use deploy
		it "serves traffic" do
			app.deploy do |app|
				expect(successful_body(app))
			end
		end
	end
	
	context "with a composer.json" do
		["5.5", "5.6", "7.0", "7.1", "7.2", "7.3"].select(&method(:php_on_stack?)).each do |series|
			context "requiring PHP #{series}" do
				let(:app) {
					Hatchet::Runner.new('test/fixtures/bootopts', stack: ENV["STACK"],
						before_deploy: -> { `composer require --no-update php "#{series}.*"; composer update --ignore-platform-reqs` }
					)
				}
				it "picks a version from the desired series" do
					app.deploy do |app|
						expect(app.output).to match(/- php \(#{Regexp.escape(series)}\./)
						expect(app.run('php -v')).to match(/#{Regexp.escape(series)}\./)
					end
				end
				
				matrices.each do |server, matrix|
					context "running the #{server} web server" do
						before(:all) do
							@app = Hatchet::Runner.new('test/fixtures/bootopts', stack: ENV["STACK"],
								before_deploy: -> { `composer require --no-update php "#{series}.*"; composer update --ignore-platform-reqs` },
							)
							@app.deploy
							# so we don't have to worry about overlapping dynos causing test failures because only one free is allowed at a time
							@app.api_rate_limit.call.formation.update(@app.name, "web", {"size" => "Standard-1X"})
						end
						
						after(:all) do
							@app.teardown!
						end
						
						# we don't want to test all possible combinations of all arguments, as that'd be thousands
						interesting = Array.new
						interesting << [0, 1] # with and without document root
						interesting << [0, '-C']
						interesting << [0, '-F']
						combinations = interesting.map {|v| genmatrix(matrix, v)}.flatten(1).uniq
						# # a few more "manual" cases
						combinations << {0 => "heroku-php-#{server}", "-C" => "conf/#{server}.server.include.conf", "-F" => "conf/fpm.include.conf"}
						combinations.each do | combination |
							context "launching using #{combination}" do
								cmd = gencmd(combination)
								it "boots" do
									# check if "timeout" killed the process successfully and exited with status 124, which means the process booted fine within five seconds
									expect_exit(expect: (combination.value?(false) or cmd.match("broken") ? :not_to : :to), code: 124) { @app.run("timeout 5 #{cmd}") }
								end
							end
						end
						
						context "launching using too many arguments" do
							it "fails to boot" do
								expect_exit(expect: :not_to, code: 124) { @app.run("timeout 5 heroku-php-#{server} docroot/ anotherarg") }
							end
						end
						
						context "launching using unknown options" do
							it "fails to boot" do
								expect_exit(expect: :not_to, code: 124) { @app.run("timeout 5 heroku-php-#{server} --what -u erp") }
							end
						end
						
						context "setting concurrency via .user.ini memory_limit" do
							it "calculates concurrency correctly" do
								expect(expect_exit(code: 124) { @app.run("timeout 5 heroku-php-#{server} docroot/") })
									.to match("16 processes at 32MB memory limit")
							end
							it "always launches at least one worker" do
								expect(expect_exit(code: 124) { @app.run("timeout 5 heroku-php-#{server} docroot/onegig/") })
									.to match("1 processes at 1024MB memory limit")
							end
							it "is only done for a .user.ini directly in the document root" do
								expect(expect_exit(code: 124) { @app.run("timeout 5 heroku-php-#{server}") })
									.to match("4 processes at 128MB memory limit")
							end
						end
						
						context "setting concurrency via FPM config memory_limit" do
							it "calculates concurrency correctly" do
								expect(expect_exit(code: 124) { @app.run("timeout 5 heroku-php-#{server} -F conf/fpm.include.conf") })
									.to match("16 processes at 32MB memory limit")
							end
							it "always launches at least one worker" do
								expect(expect_exit(code: 124) { @app.run("timeout 5 heroku-php-#{server} -F conf/fpm.onegig.conf") })
									.to match("1 processes at 1024MB memory limit")
							end
							it "takes precedence over a .user.ini memory_limit" do
								expect(expect_exit(code: 124) { @app.run("timeout 5 heroku-php-#{server} -F conf/fpm.include.conf docroot/onegig/") })
									.to match("16 processes at 32MB memory limit")
							end
						end
						
						context "setting WEB_CONCURRENCY explicitly" do
							it "uses the explicit value" do
								expect(expect_exit(code: 124) { @app.run("timeout 5 heroku-php-#{server}", nil, {:heroku => {:env => "WEB_CONCURRENCY=22"}}) })
									.to match "Using WEB_CONCURRENCY=22"
							end
							it "overrides a .user.ini memory_limit" do
								expect(expect_exit(code: 124) { @app.run("timeout 5 heroku-php-#{server} docroot/onegig/", nil, {:heroku => {:env => "WEB_CONCURRENCY=22"}}) })
									.to match "Using WEB_CONCURRENCY=22"
							end
							it "overrides an FPM config memory_limit" do
								expect(expect_exit(code: 124) { @app.run("timeout 5 heroku-php-#{server} -F conf/fpm.onegig.conf", nil, {:heroku => {:env => "WEB_CONCURRENCY=22"}}) })
									.to match "Using WEB_CONCURRENCY=22"
							end
						end
					end
				end
			end
		end
	end
end
