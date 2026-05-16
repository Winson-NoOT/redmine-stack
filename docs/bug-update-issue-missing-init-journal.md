# Bug Report: `update_issue` in `redmine_mcp` — Missing `init_journal` & No `reason` Support

## Summary

Two related bugs exist in `redmine_mcp/lib/redmine_mcp/tools.rb` inside the
`update_issue` implementation. Together they cause:

1. **Silent data loss** — field changes (status, assignee, etc.) are saved with
   no audit journal entry when `notes` is omitted.
2. **Hard block** — the update is rejected with
   `"Reason cannot be blank when changing tracked fields"` when `notes` is
   supplied but the `redmine_issue_update_statistics` plugin is active and a
   tracked field is changed.

---

## Environment

| Component | Version |
|-----------|--------|
| Redmine | 6.1.2 |
| redmine_mcp | 1.0.0 |
| redmine_issue_update_statistics | 0.0.1 |
| Ruby / Rails | 3.4 / 7.2 |

---

## Bug 1 — Silent update, no audit trail (missing `init_journal`)

### Root cause

`init_journal` in Redmine serves **two independent roles**:

| Role | Effect |
|------|--------|
| **Audit setup** | Initialises `@current_journal` with the acting user. Redmine's `after_save` callback inspects this to record which fields changed and who changed them. |
| **Notes carrier** | Optionally attaches a text comment. The `notes` argument defaults to `""` and is entirely optional. |

Redmine's own `IssuesController#update_issue_from_params` always calls it
unconditionally **before** touching any attributes:

```ruby
# app/controllers/issues_controller.rb:566
@issue.init_journal(User.current)   # no condition — always called
```

The MCP plugin only called it when `notes` was present:

```ruby
# lib/redmine_mcp/tools.rb (buggy)
issue.init_journal(user, args['notes']) if args['notes'].present?
```

When `notes` is absent:
- `@current_journal` stays `nil`.
- Redmine's `after_save` callback finds no journal and writes **no detail
  records** for the changed fields.
- The status/assignee change is persisted to the database but is **completely
  invisible** in the issue history.

### Reproduction

```ruby
user  = User.find(1)
Issue.where(id: 2).update_all(status_id: 1)

issue = Issue.visible(user).find_by(id: 2)  # fresh load — matches MCP path
# NO init_journal call
issue.status_id = 2

before_count = issue.journals.count
issue.save
issue.reload

puts issue.journals.count == before_count
# => true — journal count unchanged; change is invisible in history
```

---

## Bug 2 — Update blocked by `validate_reason` (no `reason` in MCP schema)

### Root cause

The `redmine_issue_update_statistics` plugin patches `Issue` with a validation
(`issue_patch.rb`) that fires on every `save`:

```ruby
# plugins/redmine_issue_update_statistics/lib/redmine_issue_update_statistics/issue_patch.rb
def validate_reason
  return if current_journal.nil?          # skipped when journal not initialised
  return unless has_tracked_field_updated?
  current_journal.reason = update_reason if update_reason.present? && current_journal.reason.blank?
  return if current_journal.reason.present?
  errors.add :base, 'Reason cannot be blank when changing tracked fields'
end
```

When `notes` **is** supplied:
- `init_journal` is called → `current_journal` is not `nil`.
- A tracked field (e.g. `status_id`) is changed.
- `validate_reason` fires and requires `issue.update_reason` to be set.
- The MCP schema has **no `reason` parameter**, so `update_reason` is always
  `nil` → save is rejected with HTTP 422.

### Reproduction

```ruby
user  = User.find(1)
Issue.where(id: 2).update_all(status_id: 1)

issue = Issue.visible(user).find_by(id: 2)
issue.init_journal(user, 'Some progress note')  # notes present
issue.status_id = 2                             # tracked field changed
# update_reason NOT set — no reason param in MCP schema

issue.save
# => false
puts issue.errors.full_messages
# => ["Reason cannot be blank when changing tracked fields"]
```

---

## How the two bugs interact

```
MCP update_issue called
        │
        ├─ notes absent ──► init_journal NOT called
        │                    current_journal = nil
        │                    validate_reason returns early (line 1)
        │                    save succeeds — but NO journal detail written
        │                    ★ BUG 1: silent change, no audit trail
        │
        └─ notes present ──► init_journal called
                             current_journal != nil
                             tracked field changed → validate_reason fires
                             update_reason is nil (not in MCP schema)
                             ★ BUG 2: save blocked — HTTP 422
```

---

## Fix

Two changes are needed in `lib/redmine_mcp/tools.rb`.

### 1. Always call `init_journal` (matches Redmine core behaviour)

```ruby
# BEFORE (buggy)
issue.init_journal(user, args['notes']) if args['notes'].present?

# AFTER (fixed)
issue.init_journal(user, args['notes'].to_s.presence)
issue.update_reason = args['reason'] if args['reason'].present?
```

`String#presence` returns `nil` when the string is blank, so passing it to
`init_journal` is safe — the journal is created with an empty notes string when
no notes are supplied, exactly like Redmine's own controller does.

### 2. Add `reason` to the `update_issue` input schema

```ruby
# Inside the update_issue tool definition, alongside :notes
notes:  { type: 'string', description: 'Comment to add' },
reason: { type: 'string', description: 'Reason for changing tracked fields '\
          '(required when the redmine_issue_update_statistics plugin is active '\
          'and a tracked field such as status or assignee is changed)' },
```

### Complete diff

```diff
--- a/lib/redmine_mcp/tools.rb
+++ b/lib/redmine_mcp/tools.rb
@@ -162,6 +162,7 @@
               parent_issue_id:  { type: 'integer', description: 'New parent issue ID' },
               notes:            { type: 'string',  description: 'Comment to add' },
+              reason:           { type: 'string',  description: 'Reason for changing tracked fields (required when the redmine_issue_update_statistics plugin is active and a tracked field such as status or assignee is changed)' },
               done_ratio:       { type: 'integer', description: 'Percentage done (0-100)' },

@@ -924,7 +925,8 @@
-      issue.init_journal(user, args['notes']) if args['notes'].present?
+      issue.init_journal(user, args['notes'].to_s.presence)
+      issue.update_reason = args['reason'] if args['reason'].present?
```

---

## Verified test results (local Redmine 6.1 with both plugins active)

| Scenario | Before fix | After fix |
|----------|-----------|----------|
| Status change, no notes, no reason | ✅ saved silently — **no journal** | ✅ saved — journal detail written |
| Status change, notes, no reason | ❌ HTTP 422 blocked | ❌ HTTP 422 blocked (correct — reason IS required) |
| Status change, notes + reason | ❌ HTTP 422 blocked (reason not in schema) | ✅ saved — journal detail + reason recorded |
| Notes only, no field change | ✅ saved | ✅ saved |

> **Why scenario 2 still blocks after the fix:** once `init_journal` is always
> called, the `validate_reason` validation can correctly enforce the plugin's
> policy. If a tracked field is changed, a `reason` must be supplied. This is
> the intended behaviour of `redmine_issue_update_statistics`.

---

## Files to change

| File | Change |
|------|--------|
| `redmine_mcp/lib/redmine_mcp/tools.rb` | Add `reason` to `update_issue` schema; always call `init_journal`; wire `update_reason` |

No migration, no other files needed.
