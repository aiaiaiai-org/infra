#!/usr/bin/env ruby
# frozen_string_literal: true

# © 2026 aiaiaiai · aiaiaiai.org
# Tests the agent review identity check without a network.

load File.join(__dir__, 'check-agent-review-identities.rb')

HEAD = 'a' * 40
OTHER = 'b' * 40
BEFORE = '2026-11-28T10:00:00Z'
AFTER = '2026-11-28T14:00:00Z'

POLICY = {
  effective_from: Time.iso8601('2026-11-28T13:00:00Z'),
  owner_accounts: ['0x0sky'],
  owner_bots: ['x0skai'],
  agents: { 'claude code' => ['claude-app[bot]'], 'codex' => ['codex-app[bot]'] }
}.freeze

def review(login, body, at: AFTER, commit: HEAD)
  { 'id' => 1, 'user' => { 'login' => login }, 'body' => body,
    'submitted_at' => at, 'commit_id' => commit }
end

def signed(tool, sha = HEAD)
  "**Review by #{tool}**\n\nReviewed head #{sha}.\n"
end

def count(items)
  violations(items, POLICY).length
end

def check(name, condition)
  abort "FAILED: #{name}" unless condition
end

# The configured file loads and keeps the transition safe: nobody is configured.
shipped = load_config(CONFIG_FILE)
check 'shipped file has an effective time', shipped[:effective_from].is_a?(Time)
check 'the owner bot is listed', shipped[:owner_bots].include?('x0skai')
check 'no agent identity is configured yet', shipped[:agents].empty?

# A dedicated identity may publish a signed review of the head it names.
check 'dedicated identity is accepted', count([review('claude-app[bot]', signed('Claude Code'))]).zero?
check 'tool names are matched without case', count([review('claude-app[bot]', signed('claude code'))]).zero?

# The owner's implementation bot publishes nothing, signed or not.
check 'owner bot signed', count([review('x0skai', signed('Claude Code'))]) == 1
check 'owner bot unsigned', count([review('x0skai', 'Looks fine.')]) == 1
check 'owner bot inline comment', count([review('X0skai', '')]) == 1

# A signed review must not come from the human owner's account, but a human's own review may.
check 'owner account signed', count([review('0x0sky', signed('Codex'))]) == 1
check 'owner account as a human', count([review('0x0sky', 'I approve this.')]).zero?

# A signature does not authenticate: the identity must belong to that tool.
check 'identity of another tool', count([review('codex-app[bot]', signed('Claude Code'))]) == 1
check 'unknown identity', count([review('someone', signed('Claude Code'))]) == 1
check 'tool with no entry', count([review('claude-app[bot]', signed('Cursor'))]) == 1

# A signed review names the head it was made on.
check 'no commit named', count([review('claude-app[bot]', "**Review by Claude Code**\n\nLooks good.")]) == 1
check 'another commit named', count([review('claude-app[bot]', signed('Claude Code', OTHER))]) == 1
check 'comment without commit_id', count([review('claude-app[bot]', signed('Claude Code')).tap { |r| r.delete('commit_id') }]).zero?

# Earlier reviews are left as they are.
check 'before the effective time', count([review('x0skai', signed('Claude Code'), at: BEFORE)]).zero?
check 'missing time is skipped', count([review('x0skai', 'x').tap { |r| r.delete('submitted_at') }]).zero?

# Several problems in one review are all reported.
check 'all problems reported', count([review('0x0sky', "**Review by Codex**\n\nNo commit.")]) == 2

puts 'Agent review identity checks passed'
