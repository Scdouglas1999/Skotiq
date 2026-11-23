"""Refuse to publish a release unless its commit is on main, green, and unpublished.

A release is published only from the commit its tag names, after that commit
reached `main` and passed every required CI check, and never over a release
that is already public: re-running a release would replace the packages,
checksums and signed manifests users are downloading.

Reads the repository with `git` and GitHub with `gh`; prints every reason it
refuses and exits 1 when there is one.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


# The checks branch protection requires on `main` (docs/branch-protection.md),
# plus the Windows Rust tests, which run on every push to `main`.
REQUIRED_CHECKS = (
    "Analyze",
    "Launch Gate",
    "Dart Tests",
    "Rust Tests (linux)",
    "Rust Tests (windows)",
    "Format Check",
    "Build Test (Desktop) (ubuntu-latest)",
)

CI_WORKFLOW = Path(__file__).resolve().parent.parent / ".github" / "workflows" / "ci.yml"


def ci_check_names(workflow_text):
    """The check-run names the jobs of a workflow produce.

    A job is named by its `name:`; a job with an `os` matrix produces one
    check per runner, named `<name> (<os>)`.
    """
    names = set()
    in_jobs = False
    name = None
    oses = None

    def close():
        if name is None:
            return
        if oses:
            names.update(f"{name} ({os_name})" for os_name in oses)
        else:
            names.add(name)

    for line in workflow_text.splitlines():
        if re.match(r"^\S", line):
            in_jobs = line.startswith("jobs:")
            continue
        if not in_jobs:
            continue
        if re.match(r"^  [\w-]+:\s*$", line):
            close()
            name, oses = None, None
            continue
        job_name = re.match(r"^    name:\s*(.+?)\s*$", line)
        if job_name:
            name = job_name.group(1).strip("'\"")
            continue
        matrix_os = re.match(r"^\s+os:\s*\[(.*)\]\s*$", line)
        if matrix_os:
            oses = [part.strip().strip("'\"") for part in matrix_os.group(1).split(",")]
    close()
    return names


def missing_required_checks(workflow_text):
    """Required checks that no job of the CI workflow produces."""
    produced = ci_check_names(workflow_text)
    return [name for name in REQUIRED_CHECKS if name not in produced]


def run(command):
    result = subprocess.run(command, text=True, capture_output=True)
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def tag_commit(tag):
    code, out, _ = run(["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}"])
    return out if code == 0 else None


def on_main(sha, main_ref):
    code, _, _ = run(["git", "merge-base", "--is-ancestor", sha, main_ref])
    return code == 0


def check_conclusions(repo, sha):
    """The latest conclusion of each check run on `sha`, by name."""
    code, out, err = run([
        "gh", "api", "--paginate",
        f"repos/{repo}/commits/{sha}/check-runs?filter=latest&per_page=100",
        "--jq", ".check_runs[] | {name, status, conclusion}",
    ])
    if code != 0:
        raise RuntimeError(f"could not read the check runs of {sha}: {err}")
    conclusions = {}
    for line in out.splitlines():
        check = json.loads(line)
        conclusions[check["name"]] = (
            check["conclusion"] if check["status"] == "completed" else check["status"]
        )
    return conclusions


def release_is_published(tag):
    """True for a public release, False for a draft or no release at all."""
    code, out, err = run(["gh", "release", "view", tag, "--json", "isDraft", "--jq", ".isDraft"])
    if code != 0:
        if "release not found" in err.lower():
            return False
        raise RuntimeError(f"could not read release {tag}: {err}")
    return out != "true"


def owner_overrides(tag):
    """Required checks the owner allowed to fail for this one release.

    Read from docs/release/gate-overrides/<tag>.txt in the tagged tree, one
    line per check: `<check name> | <why the owner accepted it>`. A line
    without a reason is ignored. An override only lets a completed, failed
    check through; a check still running, skipped or missing is refused as
    before, and every override used is printed as a warning on the run.
    """
    path = Path("docs/release/gate-overrides") / f"{tag}.txt"
    if not path.is_file():
        return {}
    overrides = {}
    for line in path.read_text().splitlines():
        if line.strip().startswith("#") or "|" not in line:
            continue
        name, reason = (part.strip() for part in line.split("|", 1))
        if name and reason:
            overrides[name] = reason
    return overrides


def refusals(tag, sha, repo, main_ref):
    reasons = []
    overrides = owner_overrides(tag)
    tagged = tag_commit(tag)
    if tagged is None:
        reasons.append(f"tag {tag} does not exist; push the tag and run the release from it")
    elif tagged != sha:
        reasons.append(f"this run builds {sha}, but {tag} names {tagged}; run the release from the tag")
    if not on_main(sha, main_ref):
        reasons.append(f"{sha} is not on {main_ref}; merge it to main (with a merge commit) before tagging")
    conclusions = check_conclusions(repo, sha)
    for name in REQUIRED_CHECKS:
        conclusion = conclusions.get(name)
        if conclusion == "failure" and name in overrides:
            print(
                f"::warning::Release gate: required check '{name}' on {sha} failed; "
                f"published under the owner's override for {tag}: {overrides[name]}",
                file=sys.stderr,
            )
        elif conclusion != "success":
            reasons.append(f"required check '{name}' on {sha} is {conclusion or 'missing'}, not success")
    if release_is_published(tag):
        reasons.append(f"release {tag} is already published; its assets are never replaced, cut a new version")
    return reasons


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sha", required=True, help="the commit this run builds")
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--main-ref", default="origin/main")
    args = parser.parse_args()
    try:
        reasons = refusals(args.tag, args.sha, args.repo, args.main_ref)
    except RuntimeError as error:
        print(f"::error::Release gate: {error}", file=sys.stderr)
        return 1
    for reason in reasons:
        print(f"::error::Release gate: {reason}", file=sys.stderr)
    if reasons:
        return 1
    print(f"Release gate: {args.tag} is {args.sha}, on {args.main_ref}, every required check green, not yet published.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
