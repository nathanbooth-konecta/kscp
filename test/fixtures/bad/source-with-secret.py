# Deliberately bad source file for KSCP negative-test suite.
# Used ONLY by test/test-negative-cases.sh — not in any image build.
# These tokens are synthetic non-secrets that match gitleaks' rule shapes:
#   - AWS access-key ID: 20 chars, AKIA prefix
#   - GitHub fine-grained PAT: github_pat_... prefix
#   - Slack bot token: xoxb-... prefix
# None of these are live credentials.

AWS_ACCESS_KEY_ID = "AKIAZ7Q2X9K3M4P5N6R8"
SLACK_BOT_TOKEN   = "xoxb-1234567890-9876543210-abcdefghijklmnopqrstuvwx"
GITHUB_PAT        = "github_pat_11ABCDEFG0123456789abcdefghij_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV"
