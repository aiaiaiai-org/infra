#!/usr/bin/env ruby
# frozen_string_literal: true

# © 2026 aiaiaiai · aiaiaiai.org
# Fails a pull request that carries an agent review published from an identity
# AGENTS.md forbids ("Reviews"). The identities are configured in
# .github/agent-identities.yml; nothing about them is hardcoded here.
#
# For every review and every review comment submitted at or after
# `effective_from`:
#   * the owner's implementation bot publishes none at all;
#   * a review signed `**Review by <Tool>**` must come from an identity listed
#     for that tool, never from an owner account;
#   * a signed review must name the full head commit it reviewed, and that must
#     be the commit the review was made on.
#
# Usage (CI):   REPO=owner/name PR_NUMBER=N ruby scripts/check-agent-review-identities.rb
# Usage (test): ruby scripts/check-agent-review-identities.rb --reviews FILE --comments FILE

require 'json'
require 'open3'
require 'time'
require 'yaml'

Encoding.default_external = Encoding::UTF_8

CONFIG_FILE = File.join(__dir__, '..', '.github', 'agent-identities.yml')
SIGNED = /\A\s*\*\*Review by ([^*\n]+?)\*\*/
SHA = /\b[0-9a-f]{40}\b/

def load_config(path)
  raw = YAML.safe_load_file(path, permitted_classes: [Time]) || {}
  from = raw.fetch('effective_from')
  logins = ->(key) { Array(raw[key]).map { |login| login.to_s.downcase } }
  agents = (raw['agents'] || {}).to_h do |tool, names|
    [tool.to_s.strip.downcase, Array(names).map { |login| login.to_s.downcase }]
  end
  { effective_from: from.is_a?(Time) ? from : Time.iso8601(from.to_s),
    owner_accounts: logins.call('owner_accounts'),
    owner_bots: logins.call('owner_bots'),
    agents: agents }
end

def submitted_at(item)
  stamp = item['submitted_at'] || item['created_at']
  stamp && Time.iso8601(stamp)
end

# Pure: the list of violations for reviews and review comments, as parsed JSON.
def violations(items, config)
  items.flat_map do |item|
    at = submitted_at(item)
    next [] if at.nil? || at < config[:effective_from]

    login = item.dig('user', 'login').to_s.downcase
    body = item['body'].to_s
    where = item['html_url'] || "item #{item['id']}"
    signed = body.match(SIGNED)

    if config[:owner_bots].include?(login)
      ["#{where}: #{login} is the owner's implementation bot and publishes no review or review comment"]
    elsif signed
      signed_violations(item, config, login, where, signed[1].strip.downcase, body)
    else
      []
    end
  end
end

def signed_violations(item, config, login, where, tool, body)
  found = []
  if config[:owner_accounts].include?(login)
    found << "#{where}: a review signed for #{tool} must not be published from the owner account #{login}"
  elsif !config[:agents].fetch(tool, []).include?(login)
    found << "#{where}: #{login} is not a configured identity of #{tool}"
  end
  shas = body.scan(SHA)
  if shas.empty?
    found << "#{where}: a signed review must name the full reviewed head commit"
  elsif item['commit_id'] && !shas.include?(item['commit_id'])
    found << "#{where}: the named commit is not the commit the review was made on"
  end
  found
end

def api(path)
  out, status = Open3.capture2('gh', 'api', '--paginate', '--slurp', path)
  abort "gh api #{path} failed" unless status.success?
  JSON.parse(out).flatten
end

def read_json(path)
  JSON.parse(File.read(path))
end

if $PROGRAM_NAME == __FILE__
  args = ARGV.each_slice(2).to_h
  config = load_config(CONFIG_FILE)
  items =
    if args['--reviews']
      read_json(args['--reviews']) + read_json(args.fetch('--comments'))
    else
      repo = ENV.fetch('REPO')
      pr = ENV.fetch('PR_NUMBER')
      abort 'Invalid PR number' unless pr.match?(/\A\d+\z/)
      api("repos/#{repo}/pulls/#{pr}/reviews") + api("repos/#{repo}/pulls/#{pr}/comments")
    end
  found = violations(items, config)
  if found.empty?
    puts "Agent review identities respected (#{items.length} review item(s) read)"
  else
    warn found
    abort "#{found.length} agent review identity violation(s); see AGENTS.md, Reviews"
  end
end
