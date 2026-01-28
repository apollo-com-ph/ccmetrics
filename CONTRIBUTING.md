# Contributing to Claude Code Metrics

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Reporting Issues

Before opening an issue, please:

1. Check existing issues to avoid duplicates
2. Include relevant details:
   - OS and version
   - Shell (bash/zsh)
   - Error messages from `~/.claude/ccmetrics.log`
   - Steps to reproduce

## Pull Requests

### Before You Start

1. Open an issue first to discuss significant changes
2. Fork the repository
3. Create a feature branch from `main`

### Code Guidelines

**Shell Scripts:**
- Use `set -euo pipefail` for safety
- Quote all variables: `"$var"` not `$var`
- Use `[[ ]]` for conditionals (bash)
- Add comments for non-obvious logic
- Test on both bash and zsh if possible

**Commit Messages:**
- Use present tense: "Add feature" not "Added feature"
- Keep first line under 72 characters
- Reference issues when relevant: "Fix #123"

### Testing Your Changes

```bash
# Run the setup script
bash setup_ccmetrics.sh

# Check logs for errors
tail -f ~/.claude/ccmetrics.log

# Verify hooks are installed
cat ~/.claude/settings.json | jq '.hooks'

# Test a Claude Code session and check metrics
```

### Submitting

1. Ensure your code follows the guidelines above
2. Test the full installation flow
3. Update documentation if needed
4. Submit a PR with a clear description

## Development Setup

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/ccmetrics.git
cd ccmetrics

# Make changes to setup_ccmetrics.sh
# The hook scripts are embedded in the setup script

# Test installation
bash setup_ccmetrics.sh
```

## Questions?

Open an issue with the "question" label.
