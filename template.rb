# frozen_string_literal: true
# otp-rails application template — supervise a Rails app's processes with OTP
# semantics (https://github.com/shishi-odoshi/otp-rails).
#
#   rails new myapp -m https://raw.githubusercontent.com/shishi-odoshi/otp-rails-template/main/template.rb
#
# Adds: the otp-rails gem, config/supervisor.rb (web + jobs), bin/supervise,
# a heartbeat initializer for the jobs child, and rake chaos:* tasks that kill
# children and assert the supervisor recovers them in under 10 seconds.

gem "otp-rails", "~> 0.1", require: false
# json 3.x breaks ActiveSupport::JSON.decode (2-arg JSON.parse) as of Rails
# 8.1.3, which crash-loops Solid Queue's serialized columns. Remove this pin
# once Rails supports json 3.
gem "json", "< 3.0"

after_bundle do
  create_file "config/supervisor.rb", <<~RUBY
    # frozen_string_literal: true
    # Plain Ruby — evaluated WITHOUT Rails (otp-rails DESIGN §9).
    strategy :rest_for_one
    max_restarts 5, within: 60
    backoff :exponential, base: 1, cap: 30

    # Declaration order is start order and defines rest_for_one semantics:
    # a web crash also restarts jobs; a jobs crash restarts only jobs.
    child :web,  adapter: :puma, port: Integer(ENV.fetch("PORT", 3000)), shutdown: 30
    child :jobs, adapter: :solid_queue, shutdown: 60,
                 env: { "OTP_RAILS_CHILD_ID" => "jobs" }
  RUBY

  create_file "bin/supervise", <<~SH
    #!/usr/bin/env bash
    # Run the app under the otp-rails supervisor. Ctrl-C drains and stops.
    set -euo pipefail
    cd "$(dirname "$0")/.."
    exec bundle exec otp-rails run config/supervisor.rb
  SH
  chmod "bin/supervise", 0o755

  initializer "otp_rails_heartbeat.rb", <<~RUBY
    # frozen_string_literal: true
    # Active heartbeat to the otp-rails supervisor (DESIGN §5). The supervisor
    # tags each child via env, so only the intended process heartbeats; the
    # helper is a silent no-op when the app runs unsupervised.
    if ENV["OTP_RAILS_CHILD_ID"]
      require "otp_rails/heartbeat"
      OtpRails::Heartbeat.start(id: ENV["OTP_RAILS_CHILD_ID"])
    end
  RUBY

  rakefile "chaos.rake", <<~'RUBY'
    # frozen_string_literal: true
    # Chaos tasks (otp-rails template): kill -9 a supervised child and assert
    # the supervisor brings it back healthy in under 10 seconds.
    # Run bin/supervise first, then: bin/rails "chaos:kill[web]"
    require "net/http"

    CHAOS_RECOVERY_DEADLINE = 10 # seconds

    def chaos_pids(pattern)
      `pgrep -f "#{pattern}"`.split.map(&:to_i) - [Process.pid]
    end

    def chaos_web_up?
      Net::HTTP.get_response(URI("http://127.0.0.1:#{ENV.fetch("PORT", 3000)}/up")).is_a?(Net::HTTPSuccess)
    rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout
      false
    end

    namespace :chaos do
      # Every alternative carries a [bracket] class so the pattern can never
      # match its own pgrep/sh invocation (the classic self-match trap), and
      # covers both the spawn cmdline and the retitled process: puma becomes
      # "puma 7.x (tcp://...)", solid queue becomes "solid-queue-supervisor(...)".
      WEB_PATTERN  = "puma .*config/pum[a].rb|pum[a] [0-9].*(tcp|unix|ssl)://|pum[a]: cluster"
      JOBS_PATTERN = "solid-queu[e]|bin/job[s]"

      CHILDREN = {
        "web" => {
          pattern: WEB_PATTERN,
          recovered: ->(killed) { (chaos_pids(WEB_PATTERN) - killed).any? && chaos_web_up? }
        },
        "jobs" => {
          pattern: JOBS_PATTERN,
          recovered: ->(killed) { (chaos_pids(JOBS_PATTERN) - killed).any? }
        }
      }.freeze

      desc "kill -9 a supervised child (web|jobs); fail unless recovered < #{CHAOS_RECOVERY_DEADLINE}s"
      task :kill, [:child] do |_, args|
        cfg = CHILDREN.fetch(args[:child]) { abort "chaos: unknown child #{args[:child].inspect} (want: #{CHILDREN.keys.join("|")})" }
        # The target may be mid-restart (e.g. rest_for_one just replaced it):
        # give it up to 10s to appear before declaring the tree down.
        target_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        pids = chaos_pids(cfg[:pattern])
        while pids.empty?
          abort "chaos: nothing matches #{cfg[:pattern]} — is bin/supervise running?" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) > target_deadline
          sleep 0.2
          pids = chaos_pids(cfg[:pattern])
        end
        victim = pids.min # lowest pid ≈ the master/supervisor process of that child
        Process.kill("KILL", victim)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        loop do
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          abort "chaos: #{args[:child]} NOT recovered #{CHAOS_RECOVERY_DEADLINE}s after SIGKILL of #{victim}" if elapsed > CHAOS_RECOVERY_DEADLINE
          break if cfg[:recovered].call(pids)
          sleep 0.2
        end
        puts format("chaos: %s recovered in %.1fs after SIGKILL of pid %d", args[:child],
                    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, victim)
      end

      desc "run every chaos task in sequence"
      task :all do
        CHILDREN.each_key do |child|
          Rake::Task["chaos:kill"].reenable
          Rake::Task["chaos:kill"].invoke(child)
        end
      end
    end
  RUBY

  say "otp-rails wired in: bin/supervise to run, bin/rails chaos:all to break things on purpose.", :green
end
