# Version Control - How This Works

This folder is now a git repository. You don't have to use git to *run*
the app - it's purely so you can track changes, roll back if something
breaks, and always know which version you're on.

## What version am I running?

- The app title bar shows it:  "US STOCK SCREENER  v1.0.0"
- The `VERSION` file holds the number
- `CHANGELOG.md` says what changed in each version

## The simple workflow (if you edit anything)

From a terminal in this folder:

    git status                 # what changed
    git add -A                 # stage everything
    git commit -m "what I did" # save a snapshot

To see history:

    git log --oneline

To undo uncommitted changes to a file:

    git checkout -- StockUI.ps1

To roll the WHOLE thing back to v1.0.0 if a change breaks it:

    git reset --hard v1.0.0

## Version numbering (semantic-ish)

Format: MAJOR.MINOR.PATCH  (e.g. 1.2.0)

- PATCH (1.0.0 -> 1.0.1): bug fix, no new features
- MINOR (1.0.0 -> 1.1.0): new feature, nothing broken
- MAJOR (1.0.0 -> 2.0.0): big change / breaking change

When you cut a new version:
1. Edit the `VERSION` file (e.g. change 1.0.0 to 1.1.0)
2. Add a section to `CHANGELOG.md` describing what changed
3. Commit, then tag it:

    git add -A
    git commit -m "v1.1.0 - <summary>"
    git tag -a v1.1.0 -m "Version 1.1.0"

## What is NOT tracked

`.gitignore` excludes runtime junk (live_prices.csv, status files,
error logs, Python cache). The screen data, trades, and pins ARE kept
so the shared package works out of the box.

## If you put this on GitHub later

    git remote add origin <your-repo-url>
    git push -u origin master --tags

That's optional - the repo works fully offline as-is.
