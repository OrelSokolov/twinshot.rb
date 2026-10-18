# frozen_string_literal: true

require "cgi/escape"
require "fileutils"
require "json"
require "pathname"

module Twinshot
  # Two reports per group folder:
  #
  # - report_for_human.html — self-contained HTML gallery: 1:1 gallery (flat,
  #   ordered by directory), with search, status filters (failures shown by
  #   default), image compare modes (side-by-side / slider / blink) and
  #   per-side copy buttons (absolute snapshot path — handy to paste into an
  #   agent). CSS and JS are inlined; screenshots referenced by relative paths.
  #   Theme built on Radix Colors (radix-ui.com/colors), light scales:
  #   slate neutrals, blue accent, red danger, green success. Each step
  #   has a fixed role (1-2 backgrounds, 3-6 borders/tints, 9 solid
  #   fills, 11-12 text) with guaranteed contrast for that pairing.
  # - report_for_agent.md — markdown for feeding to LLM agents: per-file
  #   metadata (paths, kind, detail, ratio) plus the divergence code snippets
  #   as unified-style ```diff fences — the same line diffs the human report
  #   renders inline (for html that's the canonicalized DOM line diff).
  #
  # Every group gets its own folder twinshot-report/<name>/ with a full
  # report_for_human.html + report_for_agent.md + summary.json + diffs/ set
  # for its results only.
  class Report
    def initialize(config, summary)
      @config = config
      @summary = summary
    end

    def write
      @summary["groups"].each do |group_stats|
        group = @config.group(group_stats["name"])
        results = @summary["results"].select { |r| r["group"] == group.name }
        write_group(group, {
                      "total" => group_stats["total"],
                      "passed" => group_stats["passed"],
                      "failed" => group_stats["failed"],
                      "results" => results
                    })
      end
      self
    end

    private

    def write_group(group, summary)
      @group = group
      @report_dir = @config.report_dir(group)
      report = Pathname.new(@report_dir)
      @oracle_prefix = Pathname.new(group.oracle_path).relative_path_from(report).to_s
      @current_prefix = Pathname.new(group.current_path).relative_path_from(report).to_s
      FileUtils.mkdir_p(@report_dir)
      File.write(File.join(@report_dir, Config::HUMAN_REPORT), render(group, summary))
      File.write(File.join(@report_dir, Config::AGENT_REPORT), agent_markdown(summary))
      File.write(File.join(@report_dir, "summary.json"), %(#{JSON.pretty_generate(summary)}\n))
    end

    def esc(text)
      CGI.escapeHTML(text.to_s)
    end

    def render(group, summary)
      # Failures are what the report is opened for; a fully green report
      # falls back to "all" so the gallery isn't empty on open.
      default_filter = summary["failed"].to_i.positive? ? "fail" : "all"
      active = ->(f) { %( class="active") if f == default_filter }
      <<~HTML
        <!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>twinshot — 1:1 parity · #{esc group.name}</title>
        <style>#{CSS}</style></head>
        <body data-filter="#{default_filter}" data-mode="side" data-heat="on">
        <header id="topbar">
          <b>twinshot</b>
          <span id="gname">#{esc group.name}</span>
          <span id="stats"><span class="ok">#{summary["passed"]}/#{summary["total"]} pass</span> <span class="bad">#{summary["failed"]} fail</span></span>
          <input id="q" type="search" placeholder="поиск по имени…">
          <span class="seg">
            <button type="button" data-f="all"#{active.call("all")}>все</button><button type="button" data-f="fail"#{active.call("fail")}>провалы</button><button type="button" data-f="pass"#{active.call("pass")}>ок</button>
          </span>
          <span class="seg">
            <button type="button" data-m="side" class="active">рядом</button><button type="button" data-m="slider">слайдер</button><button type="button" data-m="blink">мигание</button>
          </span>
          <span class="seg">
            <button type="button" data-h="on" class="active" aria-pressed="true">зоны</button>
          </span>
          <span class="hint">n/p — навигация · ⧉ — копировать путь</span>
        </header>
        #{gallery(summary)}
        </body><script>#{JS}</script></html>
      HTML
    end

    def gallery(summary)
      summary["results"]
        .group_by { |r| File.dirname(r["rel"]) }
        .sort.map { |dir, results| section(dir, results) }.join
    end

    # Sections stay as invisible containers (no headings: the dir name already
    # appears in every shot's h3, extra titles only duplicated it) so filtering
    # can still hide empty directories as a unit.
    def section(dir, results)
      %(<section class="group" data-dir="#{esc dir}">#{results.map { |r| shot(r) }.join}</section>)
    end

    def shot(result)
      rel = result["rel"]
      body = if result["image"]
               image_pair(result)
             elsif result["diff"]
               text_diff(result)
             else
               %(<p class="note">#{esc result["detail"]}</p>)
             end
      diff_link = if result["diff_image"]
                    %( <a href="#{esc result["diff_image"]}">diff</a>)
                  else
                    ""
                  end
      "<div class=\"shot #{result["status"]}\" data-name=\"#{esc rel}\">" \
        "<h3>#{esc rel}<span class=\"badge\">#{esc result["kind"]}</span>#{copy_buttons(result)}#{diff_link} " \
        "<span class=\"detail\">#{esc result["detail"]}</span></h3>" \
        "#{body}</div>"
    end

    # Copy buttons carry the absolute snapshot path (per side) so it can be
    # pasted straight into an agent or a shell. Structure rows have only one side.
    def copy_buttons(result)
      rel = result["rel"]
      if result["kind"] == "structure"
        label, root = if result["detail"].start_with?("missing")
                        ["oracle",
                         @group.oracle_path]
                      else
                        ["current", @group.current_path]
                      end
        copy_button(label, File.join(root, rel))
      else
        copy_button("oracle", File.join(@group.oracle_path, rel)) +
          copy_button("current", File.join(@group.current_path, rel))
      end
    end

    def copy_button(label, path)
      %(<button type="button" class="copy" data-copy="#{esc path}" data-label="⧉ #{label}">⧉ #{label}</button>)
    end

    def image_pair(result)
      rel = result["rel"]
      oracle_src = "#{@oracle_prefix}/#{rel}"
      current_src = "#{@current_prefix}/#{rel}"
      heat = heat_layer(result["heat"])
      badge = current_badge(result)
      <<~HTML
        <div class="pair">
          <figure class="side-a">
            <figcaption>oracle</figcaption>
            <div class="imgwrap">
              <img loading="lazy" src="#{esc oracle_src}" alt="oracle">
              <img loading="lazy" class="overlay" src="#{esc current_src}" alt="current">
              #{heat}
            </div>
            <input class="slider" type="range" min="0" max="100" value="50" aria-label="compare slider">
          </figure>
          <figure class="side-b">
            <figcaption>current #{badge}</figcaption>
            <div class="imgwrap"><img loading="lazy" src="#{esc current_src}" alt="current">#{heat}</div>
          </figure>
        </div>
      HTML
    end

    # Right-side caption badge: makes it obvious the right image IS the
    # current snapshot even when it looks identical to the oracle.
    def current_badge(result)
      if result["detail"] == "bytes equal"
        %(<span class="cbadge ok">≡ byte-equal</span>)
      elsif result["ratio"]
        css = result["status"] == "pass" ? "ok" : "warn"
        %(<span class="cbadge #{css}">#{format("%.3f%%", result["ratio"] * 100)}</span>)
      else
        %(<span class="cbadge warn">#{esc result["detail"]}</span>)
      end
    end

    # Purple overlay marking divergence zones: one positioned <i> per heat
    # cell, all in a single flat tone (no per-cell intensity scaling) so
    # the zones read as one uniform layer; the report CSS pulses it every
    # two seconds (smooth ease-in-out) so differences catch the eye — except
    # in blink mode, where the compare image itself flashes and a pulsing
    # layer would only distract. Percent-based sizing keeps it glued to
    # the image in every display mode.
    def heat_layer(heat)
      return "" unless heat

      cells = heat["cells"].map do |col, row, _intensity|
        left = col * heat["cell"].fdiv(heat["w"]) * 100
        top = row * heat["cell"].fdiv(heat["h"]) * 100
        width = [heat["cell"], heat["w"] - col * heat["cell"]].min.fdiv(heat["w"]) * 100
        height = [heat["cell"], heat["h"] - row * heat["cell"]].min.fdiv(heat["h"]) * 100
        box = "left:#{left.round(2)}%;top:#{top.round(2)}%;width:#{width.round(2)}%;height:#{height.round(2)}%"
        %(<i style="#{box};background:rgba(160,32,240,0.3)"></i>)
      end.join
      %(<div class="heat" aria-hidden="true">#{cells}</div>)
    end

    def text_diff(result)
      rel = result["rel"]
      lines = result["diff"].map { |e| %(<span class="#{e["t"]}">#{esc e["text"]}</span>) }.join
      <<~HTML
        <pre class="diff">#{lines}</pre>
        <p class="note">оригиналы: <a href="#{esc File.join(@oracle_prefix, rel)}">oracle</a> · <a href="#{esc File.join(@current_prefix, rel)}">current</a></p>
      HTML
    end

    # Markdown report aimed at LLM agents: every failed file gets a section
    # with its metadata (absolute per-side paths, kind, detail, ratio) and,
    # where the adapter produced one, the line diff in a ```diff fence —
    # the same diff the human report shows inline. Passed files are a plain
    # list: no diffs to analyze, just proof they matched.
    def agent_markdown(summary)
      failed = summary["results"].select { |r| r["status"] == "fail" }
      passed = summary["results"].select { |r| r["status"] == "pass" }
      lines = [
        "# twinshot — 1:1 parity · group #{@group.name}", "",
        "- oracle: #{@group.oracle_path}",
        "- current: #{@group.current_path}",
        "- total: #{summary["total"]} · passed: #{summary["passed"]} · failed: #{summary["failed"]}",
        "",
        "## Failures (#{failed.size})", ""
      ]
      failed.each { |r| lines.concat(agent_section(r)) }
      lines.concat(["## Passed (#{passed.size})", ""])
      passed.each { |r| lines << "- `#{r["rel"]}` — #{r["kind"]}: #{r["detail"]}" }
      lines << ""
      lines.join("\n")
    end

    def agent_section(result)
      rel = result["rel"]
      lines = ["### #{rel}", "",
               "- kind: #{result["kind"]}",
               "- status: #{result["status"]}",
               "- detail: #{result["detail"]}"]
      if result["kind"] == "structure"
        side = result["detail"].start_with?("missing") ? "oracle" : "current"
        root = side == "oracle" ? @group.oracle_path : @group.current_path
        lines << "- #{side}: #{File.join(root, rel)}"
      else
        lines << "- oracle: #{File.join(@group.oracle_path, rel)}"
        lines << "- current: #{File.join(@group.current_path, rel)}"
      end
      lines << "- ratio: #{format("%.4f", result["ratio"])}" if result["ratio"]
      lines << "- diff image: #{result["diff_image"]}" if result["diff_image"]
      lines << ""
      if result["diff"]
        lines << "````diff"
        result["diff"].each { |e| lines << agent_diff_line(e) }
        lines << "````"
        lines << ""
      end
      lines
    end

    # Unified-diff prefixes; a four-backtick fence so file content containing
    # triple backticks cannot break out of the block.
    def agent_diff_line(entry)
      case entry["t"]
      when "same" then " #{entry["text"]}"
      when "del" then "-#{entry["text"]}"
      when "add" then "+#{entry["text"]}"
      else entry["text"].to_s
      end
    end

    # Radix Colors light theme (radix-ui.com/colors). Steps: 1-2 backgrounds,
    # 3-4 tints, 5-6 borders, 7-8 borders/hover, 9-10 solid fills, 11-12 text.
    # blue-a5 is Radix blueA5 — the standard light-theme focus ring.
    CSS = <<~'CSS'
      :root{--slate-1:#fcfcfd;--slate-2:#f9f9fb;--slate-3:#f0f0f3;--slate-4:#e8e8ec;--slate-5:#e0e1e6;--slate-6:#d9d9e0;--slate-7:#cdced6;--slate-8:#b9bbc6;--slate-9:#8b8d98;--slate-10:#80838d;--slate-11:#60646c;--slate-12:#1c2024;
      --blue-4:#d5efff;--blue-5:#c2e5ff;--blue-6:#acd8fc;--blue-7:#8ec8f6;--blue-8:#5eb1ef;--blue-9:#0090ff;--blue-10:#0588f0;--blue-11:#0d74ce;--blue-12:#113264;
      --red-2:#fff7f7;--red-3:#feebec;--red-4:#ffdbdc;--red-6:#fdbdbe;--red-7:#f4a9aa;--red-9:#e5484d;--red-11:#ce2c31;
      --green-2:#f4fbf6;--green-3:#e6f6eb;--green-4:#d6f1df;--green-6:#adddc0;--green-9:#30a46c;--green-11:#218358;--blue-a5:#0093ff3d}
      body{font:14px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;margin:0;color:var(--slate-12);background:var(--slate-4);padding-bottom:48px}
      a{color:var(--blue-11)}
      #topbar{position:sticky;top:0;z-index:30;display:flex;flex-wrap:wrap;gap:10px;align-items:center;padding:8px 16px;background:#fff;border-bottom:1px solid var(--slate-6)}
      #topbar b{font-size:15px;color:var(--blue-11)}
      #gname{font:600 12px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--slate-11);background:var(--slate-2);border:1px solid var(--slate-6);padding:2px 8px;border-radius:.375rem}
      #stats .ok{color:#fff;background:var(--green-9);padding:2px 8px;border-radius:.375rem;font-weight:600}
      #stats .bad{color:#fff;background:var(--red-9);padding:2px 8px;border-radius:.375rem;font-weight:600}
      #q{width:200px;padding:4px 10px;border:1px solid var(--slate-6);border-radius:.375rem;color:var(--slate-12);font:inherit}
      #q:focus{outline:0;border-color:var(--blue-8);box-shadow:0 0 0 .25rem var(--blue-a5)}
      .seg{display:inline-flex}
      .seg button{border:1px solid var(--slate-6);background:#fff;color:var(--slate-12);padding:4px 12px;cursor:pointer;font:inherit;font-weight:500;line-height:1.4}
      .seg button:hover{background:var(--slate-3)}
      .seg button:focus-visible{outline:0;position:relative;z-index:1;box-shadow:0 0 0 .25rem var(--blue-a5)}
      .seg button+button{margin-left:-1px}
      .seg button:first-child{border-radius:.375rem 0 0 .375rem}
      .seg button:last-child{border-radius:0 .375rem .375rem 0}
      .seg button.active{background:var(--blue-9);border-color:var(--blue-9);color:#fff}
      .hint{margin-left:auto;color:var(--slate-11);font-size:12px}
      .group{max-width:1200px;margin:0 auto;padding:24px 16px 0}
      .shot{background:#fff;border:1px solid var(--slate-6);border-radius:.5rem;margin:0 0 24px;box-shadow:0 1px 2px rgba(0,0,0,.1)}
      .shot.fail{border-color:var(--red-7)}
      .shot h3{margin:0;padding:8px 12px;font:600 13px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--slate-12);background:var(--slate-2);border-bottom:1px solid var(--slate-6);border-radius:.5rem .5rem 0 0;word-break:break-all}
      .shot.fail h3{background:var(--red-3);border-bottom-color:var(--red-7);color:var(--red-11)}
      .shot>*:last-child{border-radius:0 0 .5rem .5rem;overflow:hidden}
      .shot .badge{font:600 10px system-ui,sans-serif;color:var(--slate-11);border:1px solid var(--slate-6);background:#fff;padding:1px 6px;margin-left:8px;vertical-align:1px;border-radius:.375rem}
      .shot .detail{font-weight:400;color:var(--slate-11)}
      .shot.fail .detail{color:var(--red-11)}
      .shot h3 a{color:var(--blue-11)}
      .copy{font:600 11px system-ui,sans-serif;color:var(--slate-11);background:#fff;border:1px solid var(--slate-6);border-radius:.375rem;padding:1px 7px;cursor:pointer;margin-left:6px;vertical-align:1px}
      .copy:hover{background:var(--slate-2)}
      .copy.done{background:var(--green-9);border-color:var(--green-9);color:#fff}
      .pair{display:flex;--cut:50%}
      body[data-mode=slider] .pair,body[data-mode=blink] .pair{display:block;position:relative}
      .pair figure{flex:1 1 50%;min-width:0;margin:0}
      .pair figure+figure{border-left:3px solid var(--slate-6)}
      .pair figcaption{padding:5px 10px;font:700 11px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--slate-11);background:var(--slate-2);border-bottom:1px solid var(--slate-6)}
      .cbadge{float:right;font:700 10px system-ui,sans-serif;padding:1px 7px;border-radius:.375rem}
      .cbadge.ok{background:var(--green-3);color:var(--green-11)}
      .cbadge.warn{background:var(--red-3);color:var(--red-11)}
      .imgwrap{position:relative}
      .pair img{display:block;width:100%;height:auto}
      .pair .overlay{display:none}
      body[data-mode=slider] .overlay,body[data-mode=blink] .overlay{display:block;position:absolute;top:0;left:0;width:100%;height:auto}
      body[data-mode=slider] .overlay{clip-path:inset(0 calc(100% - var(--cut)) 0 0)}
      body[data-mode=blink] .overlay{animation:blink 1s steps(1) infinite}
      body[data-filter=fail][data-mode=blink] .overlay{animation-duration:2s}
      body[data-mode=slider] .side-b,body[data-mode=blink] .side-b{display:none}
      .heat{position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none}
      .heat i{position:absolute;display:block;animation:heat-pulse 2s ease-in-out infinite}
      body[data-mode=blink] .heat i{animation:none}
      body[data-heat=off] .heat{display:none}
      @media (prefers-reduced-motion: reduce){.heat i{animation:none}}
      @keyframes blink{0%,50%{opacity:1}50.01%,100%{opacity:0}}
      @keyframes heat-pulse{0%,100%{opacity:1}50%{opacity:.15}}
      .slider{display:none;width:100%;accent-color:var(--blue-9)}
      body[data-mode=slider] .slider{display:block}
      pre.diff{margin:0;padding:8px 0;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;overflow:auto;max-height:480px;background:#fff}
      pre.diff span{display:block;padding:0 10px;white-space:pre}
      pre.diff .del{background:var(--red-3);color:var(--red-11)}
      pre.diff .add{background:var(--green-3);color:var(--green-11)}
      pre.diff .same{color:var(--slate-11)}
      .note{padding:6px 12px;color:var(--slate-11);border-top:1px solid var(--slate-6)}
    CSS

    JS = <<~'JS'
      (function () {
        var body = document.body;
        var search = document.getElementById('q');

        function apply() {
          var filter = body.dataset.filter;
          var q = search.value.trim().toLowerCase();
          document.querySelectorAll('.group').forEach(function (g) {
            var shown = 0;
            var shots = g.querySelectorAll('.shot');
            shots.forEach(function (s) {
              var visible = (filter === 'all' || s.classList.contains(filter)) &&
                            (!q || s.dataset.name.toLowerCase().indexOf(q) >= 0);
              s.hidden = !visible;
              if (visible) shown++;
            });
            g.hidden = shown === 0;
          });
        }

        document.querySelectorAll('button[data-f]').forEach(function (b) {
          b.addEventListener('click', function () {
            document.querySelectorAll('button[data-f]').forEach(function (x) { x.classList.remove('active'); });
            b.classList.add('active');
            body.dataset.filter = b.dataset.f;
            apply();
          });
        });

        document.querySelectorAll('button[data-m]').forEach(function (b) {
          b.addEventListener('click', function () {
            document.querySelectorAll('button[data-m]').forEach(function (x) { x.classList.remove('active'); });
            b.classList.add('active');
            body.dataset.mode = b.dataset.m;
          });
        });

        document.querySelectorAll('button[data-h]').forEach(function (b) {
          b.addEventListener('click', function () {
            var off = body.dataset.heat === 'off';
            body.dataset.heat = off ? 'on' : 'off';
            b.classList.toggle('active', off);
            b.setAttribute('aria-pressed', String(off));
          });
        });

        document.addEventListener('input', function (e) {
          if (e.target.classList && e.target.classList.contains('slider')) {
            e.target.closest('.pair').style.setProperty('--cut', e.target.value + '%');
          }
        });

        function markCopied(btn) {
          btn.classList.add('done');
          btn.textContent = '✓ скопировано';
          setTimeout(function () {
            btn.classList.remove('done');
            btn.textContent = btn.dataset.label;
          }, 1200);
        }

        function copyText(text, btn) {
          var fallback = function () {
            var ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            try { document.execCommand('copy'); markCopied(btn); } catch (e) {}
            document.body.removeChild(ta);
          };
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(function () { markCopied(btn); }, fallback);
          } else {
            fallback();
          }
        }

        document.addEventListener('click', function (e) {
          var btn = e.target.closest ? e.target.closest('button.copy') : null;
          if (btn) copyText(btn.dataset.copy, btn);
        });

        function visibleShots() {
          return Array.prototype.slice.call(document.querySelectorAll('.shot')).filter(function (s) {
            return !s.hidden && s.getBoundingClientRect().height > 0;
          });
        }

        document.addEventListener('keydown', function (e) {
          if (e.target === search) {
            if (e.key === 'Escape') { search.value = ''; apply(); search.blur(); }
            return;
          }
          if (e.key !== 'n' && e.key !== 'p') return;
          var shots = visibleShots();
          if (!shots.length) return;
          var current = shots.length - 1;
          for (var i = 0; i < shots.length; i++) {
            if (shots[i].getBoundingClientRect().top >= 60) { current = i; break; }
          }
          var target = e.key === 'n' ? Math.min(current + 1, shots.length - 1) : Math.max(current - 1, 0);
          shots[target].scrollIntoView({ block: 'start' });
        });

        search.addEventListener('input', apply);
        apply();
      })();
    JS
  end
end
