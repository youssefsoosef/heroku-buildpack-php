require_relative "php_shared"

describe "A PHP 7.4 application with a composer.json", :requires_php_on_stack => "7.4" do
	include_examples "A PHP application with a composer.json", "7.4"
	
	context "with an index.php that allows for different execution times" do
		['apache2', 'nginx'].each do |server|
			context "running the #{server} web server" do
				let(:app) {
					new_app_with_stack_and_platrepo('test/fixtures/sigterm',
						before_deploy: -> { FileUtils.cp("#{__dir__}/../utils/wait-for-it.sh", FileUtils.pwd); system("composer require --quiet --ignore-platform-reqs php '7.4.*'") or raise "Failed to require PHP version" }
					)
				}
				
				# FIXME: move to php_shared.rb once all PHPs are rebuilt with that tracing capability
				it "logs slowness after configured time and sees a trace" do
					app.deploy do |app|
						# launch web server wrapped in a 20 second timeout
						# once web server is ready, `read` unblocks and we curl the sleep() script which will take a few seconds to run
						# after `curl` completes, `wait-for.it.sh` will shut down
						# ensure slowlog info and trace is there
						cmd = "./wait-for-it.sh 20 'ready for connections' heroku-php-apache2 --verbose -F fpm.request_slowlog_timeout.conf | { read && curl \"localhost:$PORT/index.php?wait=5\"; }"
						output = app.run(cmd)
						expect(output).to include("executing too slow")
						expect(output).to include("sleep() /app/index.php:5")
					end
				end
				
				it "logs slowness after about 3 seconds and terminates the process after about 30 seconds" do
					app.deploy do |app|
						# launch web server wrapped in a 50 second timeout
						# once web server is ready, `read` unblocks and we curl the sleep() script with a very long timeout
						# after `curl` completes, `wait-for.it.sh` will shut down
						# ensure slowlog and terminate output is there
						cmd = "./wait-for-it.sh 50 'ready for connections' heroku-php-apache2 --verbose | { read && curl \"localhost:$PORT/index.php?wait=35\"; }"
						output = app.run(cmd)
						expect(output).to match(/executing too slow/)
						expect(output).to match(/execution timed out/)
					end
				end
			end
		end
	end
end
