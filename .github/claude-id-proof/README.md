# Synthetic Claude hook identifier probe

This is a CI-only experiment, not an application integration. It runs pinned
official Windows packages from the npm registry using a temporary profile,
synthetic hook configuration and a loopback Messages API stub. The CLI receives
only a fake API key and fixed synthetic prompts. The runtime environment is
allowlisted; HOME and CODEX_HOME are not assigned. A temporary Windows Firewall
rule blocks outbound connections for the tested executable (for 2.1.101, its
Node host). It is removed on the disposable runner after the probe. This rule
does not by itself prove that arbitrary descendants cannot reach the network.

The downloaded archives are verified against these SHA-512 values from the
official package metadata:

- `@anthropic-ai/claude-code@2.1.101`:
  `sha512-abVVCKMDKl9jHzgoUhhBVAQY2fKVdLt13ag5EEDlybRUCRL+rEAZfBxOdQnKZbzH1AUW5VwqiELeMHFauO51DQ==`
- `@anthropic-ai/claude-code-win32-x64@2.1.273`:
  `sha512-1NmQNk18bb58Ud6Z0ob5KxJRixDBzUifry3KXpHnKFxG0Df5h9ko6MlvRNuL+6ROmmgycLhYRl5jBZqwc0USQw==`

On commit `29101d52952f99135308e320852f7f55ce66a0df`,
[hosted run 43876744993](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43876744993)
passed for both versions. Each job issued two synthetic user prompts in one
session, with two Read tool calls per prompt, and observed two UserPromptSubmit,
four PreToolUse and four PostToolUse events. Tool-use identifiers uniquely
paired the synthetic calls in both versions.

In the 2.1.101 job, all ten of those events lacked the `prompt_id` field. In
the 2.1.273 job, all ten had a string `prompt_id`; it matched within each
synthetic prompt and differed between the two prompts. This establishes only
the observed normal sequences for these exact packages and test environment.
It does not establish when the field was introduced, behavior for intermediate
versions, delayed or interrupted turns, real model/network responses, or
backwards compatibility of the released monitor's journal format. The existing
hook does not currently preserve either identifier. Do not promote a plan to
confirmed status based on an absent identifier or on this experiment alone.

User, machine and process PATH values and registry kinds were checked and
unchanged in the hosted run. The probe does not open a real account, local
user profile or existing Claude hooks. It does not install a plugin or change
any user settings. The user-approved minimum Claude Code version remains
2.1.101.
