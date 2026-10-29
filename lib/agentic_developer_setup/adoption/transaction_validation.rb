# frozen_string_literal: true

require "open3"
require_relative "plan_validator"

module AgenticDeveloperSetup
  module Adoption
    class TransactionValidation
      include TransactionSupport

      OUTPUT_LIMIT = 65_536
      SECRET_NAME = /TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_?KEY|AUTH|COOKIE|(?:API|ACCESS|SIGNING|ENCRYPTION|HMAC|CLIENT|SSH)_?KEY|ASKPASS|(?:\A|_)KEY(?:\z|_)/i
      ENV_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      def self.validate_commands!(commands)
        TransactionSupport.schema!("validation", {"schema_version" => 1, "commands" => commands})
        ids = commands.map { |item| item["id"] }
        TransactionSupport.fail!("invalid_document", "duplicate validation command IDs", 2) unless ids.uniq == ids
        commands.each do |command|
          TransactionSupport.fail!("invalid_document", "empty executable or NUL in command arguments", 2) if command["argv"].first.strip.empty? || command["argv"].any? { |arg| arg.include?("\0") }
          command["env"].each do |key, value|
            if !key.match?(ENV_NAME) || key.match?(SECRET_NAME) || value.include?("\0")
              TransactionSupport.fail!("invalid_document", "unsafe validation environment declaration", 2)
            end
          end
        end
      end

      def initialize(validator)
        @validator = validator
        @plan = validator.plan
      end

      def run(application_result:, output:, plan_path:)
        roots = @validator.roots
        application_path = external(application_result, roots, present: true)
        destination = external(output, roots, new_file: true)
        identities_distinct!([application_path, destination, plan_path, *@validator.input_paths])
        application_digest = digest(File.binread(application_path))
        application = schema!("application-result", load_yaml(application_path))
        validate_application!(application)
        self.class.validate_commands!(@plan["validation_commands"])
        specification = @plan.dig("inputs", "validation_spec")
        if specification
          specification_path = external(specification["path"], roots, present: true)
          fail!("plan_stale", "approved validation specification changed") unless digest(File.binread(specification_path)) == specification["digest"]
          approved = schema!("validation", load_yaml(specification_path))
          fail!("invalid_document", "embedded commands differ from approved validation specification", 2) unless approved["commands"] == @plan["validation_commands"]
        else
          fail!("invalid_document", "commands require an explicit validation specification", 2) unless @plan["validation_commands"].empty?
        end
        actual_root, = repository(roots.first, "target", clean: false)
        fail!("invalid_target", "target canonical identity changed", 3) unless actual_root == roots.first
        @validator.verify_outputs!
        state_before = repository_snapshot
        result = {"schema_version" => 1, "plan_id" => @plan["plan_id"], "application_status" => application["status"],
                  "started_at" => now, "finished_at" => now, "status" => "passed", "commands" => [], "diagnostics" => []}
        if @plan["validation_commands"].empty?
          result["status"] = "skipped"
          result["diagnostics"] << diagnostic("validation_skipped", "No validation commands were approved.", severity: "warning")
        else
          @plan["validation_commands"].each do |command|
            command_result = execute(command)
            result["commands"] << command_result
            next if command_result["status"] == "passed"
            result["status"] = (command_result["status"] == "unavailable") ? "unavailable" : "failed"
            code = (result["status"] == "unavailable") ? "validation_unavailable" : "validation_failed"
            result["diagnostics"] << diagnostic(code, "Validation command #{command["id"]} did not succeed.")
            break
          end
        end
        begin
          if repository_snapshot != state_before
            result["status"] = "failed"
            result["diagnostics"] << diagnostic("validation_failed", "Validation changed tracked or untracked repository content or Git state.")
          end
        rescue TransactionError, SystemCallError, IOError => e
          result["status"] = "failed"
          result["diagnostics"] << diagnostic("validation_failed", "Post-validation repository inspection unavailable: #{e.message}")
        end
        begin
          @validator.verify_outputs!
        rescue TransactionError, SystemCallError, IOError, Assessment::Error => e
          result["status"] = "failed"
          result["diagnostics"] << diagnostic("validation_failed", e.message)
        end
        begin
          fail!("plan_stale", "application evidence changed during validation") unless digest(File.binread(application_path)) == application_digest
        rescue TransactionError, SystemCallError, IOError => e
          result["status"] = "failed"
          result["diagnostics"] << diagnostic("validation_failed", e.message)
        end
        result["finished_at"] = now
        result["diagnostics"] = sorted_diagnostics(result["diagnostics"])
        schema!("validation-result", result)
        fail!("unsafe_path", "validation result destination changed") unless external(output, roots, new_file: true) == destination
        atomic_write(destination, YAML.dump(canonical(result)), create: true)
        [result, {"passed" => 0, "skipped" => 4, "failed" => 6, "unavailable" => 6}.fetch(result["status"])]
      end

      private

      def validate_application!(application)
        fail!("plan_identity_mismatch", "application evidence does not match plan") unless application["plan_id"] == @plan["plan_id"] && application["target"] == @plan["target"] && application["source"] == @plan["source"] && application["operation"] == @plan["operation"]
        fail!("preflight_failed", "validation requires completed matching application evidence") unless %w[applied_unvalidated no_changes].include?(application["status"]) && application["finished_at"] && application["metadata"]["verified"] && !application["recovery"]["interruption_uncertainty"]
        fail!("invalid_document", "application metadata identity differs", 2) unless application["metadata"]["actual_digest"] == @validator.metadata_expected_digest
        expected_status = @validator.changed? ? "applied_unvalidated" : "no_changes"
        fail!("invalid_document", "application status does not match plan effects", 2) unless application["status"] == expected_status
        actions = application["actions"]
        fail!("invalid_document", "application action count differs", 2) unless actions.length == @plan["actions"].length
        actions.zip(@plan["actions"]).each do |evidence, action|
          file = action["target_file"]
          valid = evidence["component_id"] == action["component_id"] && evidence["action"] == action["action"] && evidence["state"] == "completed" && evidence["diagnostics"].empty? && evidence["target_path"] == file&.fetch("path") && evidence["reviewed_content"] == action["reviewed_content"]
          if file
            valid &&= evidence["previous"] == {"digest" => file["expected_digest"], "mode" => file["expected_mode"]} && evidence["intended"] == {"digest" => file["result_digest"], "mode" => file["result_mode"]} && evidence["observed"] == evidence["intended"]
          end
          fail!("invalid_document", "application action evidence differs", 2) unless valid
        end
      end

      def repository_snapshot
        root = @validator.roots.first
        head = GitCommand.revision(root)
        paths = git!(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0").uniq.sort
        files = paths.to_h do |relative|
          path = root.join(relative)
          identity = if path.symlink?
            ["symlink", File.readlink(path)]
          elsif path.file?
            [digest(File.binread(path)), mode(path)]
          elsif path.directory?
            ["directory"]
          else
            ["missing"]
          end
          [relative, identity]
        end
        [head, git_state(root), files, git!(root, "ls-files", "--stage", "-z")]
      end

      def execute(command)
        root = @validator.roots.first
        cwd = (command["cwd"] == "scope") ? safe_path(root, @plan.dig("target", "scope", "path")) : root
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # No HOME, inherited credentials, Git variables, shell functions or runtime options.
        environment = {"PATH" => ENV.fetch("PATH", "/usr/bin:/bin"), "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8", "TZ" => "UTC"}.merge(command["env"])
        stdout = stderr = ""
        stdout_truncated = stderr_truncated = false
        exit_status = nil
        status = "unavailable"
        begin
          # [executable, argv0] forces direct exec even for a single string with shell syntax.
          argv = command["argv"]
          Open3.popen3(environment, [argv.first, argv.first], *argv.drop(1), chdir: cwd.to_s, unsetenv_others: true) do |stdin, out, err, wait|
            stdin.close
            readers = [out, err].map { |stream| Thread.new { bounded_read(stream) } }
            stdout, stdout_truncated = readers[0].value
            stderr, stderr_truncated = readers[1].value
            process_status = wait.value
            exit_status = process_status.exitstatus || (128 + process_status.termsig).clamp(0, 255)
            status = (exit_status == command["expected_exit_code"]) ? "passed" : "failed"
          end
        rescue SystemCallError => e
          stderr = e.message.byteslice(0, OUTPUT_LIMIT)
        end
        {"id" => command["id"], "argv" => command["argv"], "cwd" => cwd.to_s, "expected_exit_code" => command["expected_exit_code"],
         "actual_exit_code" => exit_status, "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
         "stdout" => utf8(stdout), "stderr" => utf8(stderr), "stdout_truncated" => stdout_truncated, "stderr_truncated" => stderr_truncated, "status" => status}
      end

      def bounded_read(stream)
        captured = +"".b
        total = 0
        loop do
          part = stream.readpartial(8192)
          total += part.bytesize
          available = OUTPUT_LIMIT - captured.bytesize
          captured << part.byteslice(0, available) if available > 0
        end
      rescue EOFError
        [captured, total > OUTPUT_LIMIT]
      end

      def utf8(value)
        value.dup.force_encoding(Encoding::UTF_8).scrub
      end
    end
  end
end
