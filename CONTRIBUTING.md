# Contributing

Thank you for your interest in contributing to this project.  
This repository provides a Bash script for generating cloud-init templates on Proxmox VE.  
Contributions are welcome as issues, bug reports, or pull requests.

## Getting started

1. Fork the repository on GitHub.
2. Clone your fork to your local machine.
3. Create a new branch for your changes:

   git checkout -b feature/my-change

4. Make your changes and test them locally.
5. Push your branch and open a pull request against the `main` branch.

## Reporting issues

When opening an issue, please include:

- A clear description of the problem or feature request.
- Your Proxmox VE version (e.g. `pveversion -v`).
- The script version or commit hash you are using.
- Relevant logs or error messages (redacted if necessary).
- Any steps required to reproduce the issue.

This makes it much easier to triage and address the problem.

## Submitting changes (Pull Requests)

Before opening a pull request:

1. Make sure your changes are focused and self-contained.
   - Avoid mixing unrelated changes in a single PR.
2. Ensure the script is still executable if applicable:

   chmod +x create_templates.sh

3. Run the basic checks locally (see below).
4. Update documentation if behavior has changed:
   - `README.md` for user-facing changes.
   - Comments in `create_templates.sh` when logic changes.

When opening the pull request:

- Provide a short summary of what you changed and why.
- Reference related issues if applicable (e.g. `Closes #12`).

## Coding style

This project uses a single Bash script with some basic conventions:

- Use `set -euo pipefail` at the top of any new scripts.
- Prefer small, well-named functions over large monolithic blocks.
- Use consistent indentation (2 spaces or 4 spaces; keep it consistent with the existing script).
- Avoid unnecessary complexity; favor clarity over cleverness.
- Prefer `$(...)` over backticks for command substitution.

If you extend the script significantly, consider adding comments for non-trivial logic so other admins understand the reasoning (especially around Proxmox or cloud-init quirks).

## Shellcheck / CI

The repository uses GitHub Actions to run `shellcheck` on the Bash script.

Before pushing changes, please run `shellcheck` locally if possible:

- If you are working on the main script in the repository root:

  shellcheck create_templates.sh

- If there are multiple scripts, you can run:

  find . -name '*.sh' -print0 | xargs -0 shellcheck

The CI pipeline will run `shellcheck` on your pull request. Please fix any reported issues before requesting a review.

## Commit messages

Please use clear, descriptive commit messages:

- Use the imperative form for the summary line, e.g.:
  - `Add shellcheck CI workflow`
  - `Fix storage pool validation`
  - `Document RESIZE_WAIT_ENABLED flag`

If you need to explain details, add a short body below the summary line.

## Backwards compatibility

If your change may break existing usage (for example, changing defaults, VMIDs, or required environment variables), please:

1. Call this out explicitly in the pull request description.
2. Update the `README.md` to describe the new behavior.
3. Where reasonable, provide a migration or fallback path.

## License

By contributing to this repository, you agree that your contributions will be licensed under the same license as the project (see the `LICENSE` file).
