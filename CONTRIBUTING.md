# Contributing to Brigade

Thanks for your interest in contributing to Brigade!

## Development Setup

```bash
git clone https://github.com/yourusername/brigade.git
cd brigade
```

No build step required - Brigade is a bash script with supporting files.

## Testing Changes

```bash
# Test with example PRD
./brigade.sh status examples/prd-example.json
./brigade.sh analyze examples/prd-example.json

# Test in a real project
cd /path/to/your/project
ln -s /path/to/brigade ./brigade
./brigade/brigade.sh service tasks/your-prd.json
```

## Project Structure

```
brigade/                    # ← Repo root (clone into your project)
├── brigade.sh              # Main CLI script
├── brigade.config.example  # Configuration reference
├── chef/                   # Worker prompts
│   ├── executive.md        #   Executive Chef (Opus) - plans & reviews
│   ├── sous.md             #   Sous Chef (Sonnet) - complex tasks
│   ├── line.md             #   Line Cook (GLM) - routine tasks
│   └── supervisor.md       #   External AI supervisor docs
├── commands/               # Claude Code skills (/brigade)
├── docs/                   # Documentation
├── examples/               # Example PRDs and configs
├── modules/                # Optional extensions (telegram, cost tracking)
├── templates/              # PRD generation templates
├── tests/                  # Test suite (bats)
│
└── brigade/                # ⚠️ Working files directory (gitignored)
    ├── tasks/              #   PRDs, state files, events
    ├── logs/               #   Worker conversation logs
    └── notes/              #   Supervisor/handoff notes
```

**Note:** The inner `brigade/` folder is for runtime working files - it's not recursive. When you clone Brigade into your project, the working files stay isolated and gitignored:

```
your-project/
├── src/
├── brigade/              # ← You clone Brigade here
│   ├── brigade.sh
│   ├── chef/
│   └── brigade/          # ← Working files (gitignored)
│       └── tasks/
└── ...
```

## Code Style

### Bash

- Use `set -e` for error handling
- Quote all variables: `"$variable"`
- Use `local` for function variables
- Add comments for non-obvious logic
- Use meaningful function names

### Documentation

- Write in plain English
- Include code examples
- Keep lines under 100 characters
- Use tables for structured information

## Submitting Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Test with real PRDs
5. Commit with clear messages
6. Open a Pull Request

## Ideas for Contribution

- [ ] Add Executive Chef review loop (Opus reviews completed work)
- [ ] Add escalation (Line Cook fails → retry with Sous Chef)
- [ ] Add web UI for monitoring service progress
- [ ] Add support for more AI CLIs
- [ ] Add parallel task execution
- [ ] Add cost tracking per task
- [ ] Add time estimates based on complexity
- [ ] Improve auto-routing heuristics

## Questions?

Open an issue for:
- Bug reports
- Feature requests
- Documentation improvements
- General questions
