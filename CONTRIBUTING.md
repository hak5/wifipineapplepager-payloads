# Contributing to Pineapple Pager Payloads

Thank you for your interest in contributing! This document provides guidelines for contributing to this repository.

## How to Contribute

### Reporting Issues

- Use the [GitHub Issues](https://github.com/sinXne0/pineapple-pager-payloads/issues) page
- Provide detailed information about the issue
- Include steps to reproduce
- Mention your Pager firmware version
- Include relevant logs or error messages

### Submitting Payloads

1. **Fork the Repository**
   ```bash
   git clone https://github.com/sinXne0/pineapple-pager-payloads.git
   cd pineapple-pager-payloads
   ```

2. **Create a Feature Branch**
   ```bash
   git checkout -b feature/my-new-payload
   ```

3. **Follow Payload Standards**
   - Use the directory structure: `library/<type>/<category>/<payload_name>/`
   - Include `payload.sh` with proper header
   - Include `README.md` with documentation
   - Follow [Hak5 payload standards](https://github.com/hak5/wifipineapplepager-payloads)

4. **Test Thoroughly**
   - Test on actual Pager hardware
   - Verify all DuckyScript commands work
   - Test error handling
   - Ensure no syntax errors

5. **Commit Your Changes**
   ```bash
   git add .
   git commit -m "Add: My New Payload"
   ```

6. **Push and Create Pull Request**
   ```bash
   git push origin feature/my-new-payload
   ```
   Then create a PR on GitHub

## Payload Standards

### File Structure

```
library/<type>/<category>/<payload_name>/
├── payload.sh          # Main executable
└── README.md           # Documentation
```

### Payload Header

Every `payload.sh` must include:

```bash
#!/bin/bash
# Title: Descriptive Payload Name
# Author: Your Name
# Description: Brief description of what it does
# Version: 1.0
# Category: type/category
```

### Configuration Section

Place all configurable options at the top:

```bash
# ============================================
# CONFIGURATION
# ============================================
OPTION1="default_value"
OPTION2=true
```

### Documentation Requirements

Every payload must include a `README.md` with:

- Description
- Features
- Requirements
- Installation instructions
- Configuration options
- Usage examples
- Troubleshooting section

### Code Standards

- Use clear, descriptive variable names
- Add comments for complex logic
- Handle errors gracefully
- Use `LOG` for user feedback
- Use proper exit codes
- Never hardcode credentials
- Use placeholder values (e.g., `example.com`)

### DuckyScript Usage

- DuckyScript commands must be UPPERCASE
- Handle user cancellation (`$DUCKYSCRIPT_CANCELLED`)
- Check exit codes properly
- Provide user feedback with `LOG`

### Example Payload Template

```bash
#!/bin/bash
# Title: Example Payload
# Author: Your Name
# Description: Example payload template
# Version: 1.0
# Category: user/general

# ============================================
# CONFIGURATION
# ============================================
SETTING1="value"

# ============================================
# MAIN EXECUTION
# ============================================

LOG green "Starting payload..."

resp=$(CONFIRMATION_DIALOG "Continue?")
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED)
        LOG "Cancelled"
        exit 0
        ;;
esac

# Your code here

LOG green "Complete!"
exit 0
```

## Commit Message Guidelines

Use clear, descriptive commit messages:

- `Add: New payload name` - New payload
- `Fix: Issue with payload` - Bug fix
- `Update: Payload improvements` - Enhancements
- `Docs: Update README` - Documentation
- `Refactor: Code cleanup` - Code improvements

## Testing Checklist

Before submitting a PR, verify:

- [ ] Payload runs without errors on Pager
- [ ] All DuckyScript commands work correctly
- [ ] Error handling works properly
- [ ] User feedback is clear and helpful
- [ ] Configuration options are documented
- [ ] README is complete and accurate
- [ ] No hardcoded credentials or sensitive data
- [ ] Code follows style guidelines
- [ ] Payload name uses underscores/hyphens (no spaces)
- [ ] File permissions are correct (755 for .sh)

## Security Considerations

### Do's
✅ Handle user input safely
✅ Validate file paths
✅ Use secure defaults
✅ Document security implications
✅ Include legal warnings

### Don'ts
❌ Include actual credentials
❌ Hardcode API keys
❌ Use `example.com` for production
❌ Include malicious code
❌ Encourage illegal use

## Legal Requirements

All contributions must:

- Be for authorized security testing only
- Include appropriate legal warnings
- Not contain malicious or destructive code
- Comply with applicable laws
- Include proper attribution

## Community Guidelines

- Be respectful and constructive
- Help others learn
- Share knowledge
- Follow the code of conduct
- Give credit where due

## Questions?

- Open a [GitHub Issue](https://github.com/sinXne0/pineapple-pager-payloads/issues)
- Check existing issues and PRs first
- Be patient and respectful

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

**Thank you for contributing to the WiFi Pineapple Pager community!**
