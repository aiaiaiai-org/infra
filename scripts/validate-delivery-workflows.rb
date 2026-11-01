#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# The delivery workflows only run on a schedule or by dispatch, never on a pull
# request, so CI checks their wiring here: they parse, each caller passes inputs
# its callee declares (and every required one), and secrets are inherited down
# to Deploy workload, which holds the SSH credentials.

require "yaml"

ROOT = File.expand_path("..", __dir__)

def workflow(name)
  path = File.join(ROOT, ".github", "workflows", name)
  YAML.safe_load(File.read(path), aliases: false)
rescue Psych::SyntaxError => e
  abort("#{name}: invalid YAML: #{e.message}")
end

def triggers(document)
  document[true] || document["on"]
end

def call_inputs(name)
  triggers(workflow(name)).fetch("workflow_call").fetch("inputs")
end

def check_call(caller_name, job_name, callee)
  job = workflow(caller_name).fetch("jobs").fetch(job_name)
  abort("#{caller_name}: #{job_name} must use ./.github/workflows/#{callee}") unless job["uses"] == "./.github/workflows/#{callee}"
  abort("#{caller_name}: #{job_name} must pass secrets: inherit") unless job["secrets"] == "inherit"

  declared = call_inputs(callee)
  passed = job.fetch("with").keys
  unknown = passed - declared.keys
  abort("#{caller_name}: #{job_name} passes undeclared inputs #{unknown.join(', ')}") unless unknown.empty?
  missing = declared.select { |_, spec| spec["required"] }.keys - passed
  abort("#{caller_name}: #{job_name} omits required inputs #{missing.join(', ')}") unless missing.empty?
end

reconcile = triggers(workflow("reconcile-deliveries.yml"))
abort("reconcile-deliveries.yml: must run on a schedule") unless reconcile.key?("schedule")
abort("reconcile-deliveries.yml: must allow workflow_dispatch") unless reconcile.key?("workflow_dispatch")
check_call("reconcile-deliveries.yml", "deliver", "deliver-workload.yml")
check_call("deliver-workload.yml", "deploy", "deploy-workload.yml")
puts "Delivery workflows: wiring validated"
