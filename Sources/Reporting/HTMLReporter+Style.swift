// MARK: - Style

extension HTMLReporter {
    static let stylesheet = """
    :root {
      --bg: #fbfbfd; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7;
      --card: #ffffff; --ok: #1a7f37; --bad: #cf222e; --warn: #9a6700;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #16171a; --fg: #f5f5f7; --muted: #98989d; --line: #38383d;
        --card: #1f2024; --ok: #3fb950; --bad: #f85149; --warn: #d29922;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 2rem 1rem; background: var(--bg); color: var(--fg);
      font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    }
    main { max-width: 60rem; margin: 0 auto; }
    h1 { font-size: 1.6rem; margin: 0 0 1rem; letter-spacing: -0.02em; }
    h2 { font-size: 1.05rem; margin: 0 0 0.6rem; letter-spacing: -0.01em; }
    h3 { font-size: 0.95rem; margin: 0 0 0.4rem; }
    code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85em; }
    .card {
      background: var(--card); border: 1px solid var(--line); border-radius: 10px;
      padding: 1rem 1.15rem; margin-bottom: 1rem;
    }
    .meta { display: grid; grid-template-columns: 7rem 1fr; gap: 0.2rem 0.75rem; margin: 0 0 1.5rem; }
    .meta dt { color: var(--muted); }
    .meta dd { margin: 0; overflow-wrap: anywhere; }
    .scores { display: grid; grid-template-columns: repeat(auto-fit, minmax(16rem, 1fr)); gap: 1rem; }
    .score .value { font-size: 2.4rem; font-weight: 600; margin: 0.2rem 0; letter-spacing: -0.03em; }
    .score .formula, .detail { color: var(--muted); margin: 0.15rem 0; font-size: 0.85rem; }
    .fail-closed { border: 2px solid var(--bad); }
    .fail-closed h2 { color: var(--bad); }
    .badge {
      font-size: 0.7rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em;
      padding: 0.15rem 0.45rem; border-radius: 5px; vertical-align: 0.15em;
    }
    .badge.ok { background: var(--ok); color: #fff; }
    .badge.bad { background: var(--bad); color: #fff; }
    table { border-collapse: collapse; width: 100%; }
    td, th { text-align: left; padding: 0.3rem 0.5rem; border-bottom: 1px solid var(--line); }
    th { color: var(--muted); font-weight: 500; }
    .num { text-align: right; font-variant-numeric: tabular-nums; }
    .outcomes tr.ok td:first-child { color: var(--ok); }
    .outcomes tr.bad td:first-child { color: var(--bad); }
    .violations li { margin-bottom: 0.5rem; }
    .violations strong { color: var(--bad); }
    .excluded { border-left: 3px solid var(--warn); }
    .survivor { border-left: 3px solid var(--bad); }
    .meta-line { margin: 0.3rem 0 0.6rem; }
    .tag {
      display: inline-block; background: var(--bg); border: 1px solid var(--line);
      border-radius: 5px; padding: 0.05rem 0.4rem; margin-right: 0.3rem;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.75rem; color: var(--muted);
    }
    pre.diff {
      background: var(--bg); border: 1px solid var(--line); border-radius: 8px;
      padding: 0.7rem; overflow-x: auto; margin: 0.5rem 0 0;
    }
    pre.diff span { display: block; white-space: pre; }
    .diff-add { color: var(--ok); }
    .diff-del { color: var(--bad); }
    .diff-meta { color: var(--muted); }
    """
}
