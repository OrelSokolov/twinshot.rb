# frozen_string_literal: true

require "cgi/escape"
require "fileutils"
require "json"
require "pathname"

module Twinshot
  # Self-contained HTML report: 1:1 gallery grouped by directory, with search,
  # status filters, image compare modes (side-by-side / slider / blink) and
  # per-side copy buttons (absolute snapshot path — handy to paste into an
  # agent). CSS and JS are inlined; screenshots referenced by relative paths.
  # White-blue high-contrast theme with a thick divider between the pair.
  class Report
    def initialize(config, summary)
      @config = config
      @summary = summary
      @report_dir = config.report_dir
      report = Pathname.new(@report_dir)
      @oracle_prefix = Pathname.new(config.oracle_path).relative_path_from(report).to_s
      @current_prefix = Pathname.new(config.current_path).relative_path_from(report).to_s
    end

    def write
      FileUtils.mkdir_p(@report_dir)
      File.write(File.join(@report_dir, "report.html"), render)
      File.write(File.join(@report_dir, "summary.json"), JSON.pretty_generate(@summary) + "\n")
      self
    end

    private

    def esc(text)
      CGI.escapeHTML(text.to_s)
    end

    def render
      <<~HTML
        <!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>twinshot — 1:1 parity</title>
        <style>#{CSS}</style></head>
        <body data-filter="all" data-mode="side" data-heat="on">
        <header id="topbar">
          <b>twinshot</b>
          <span id="stats"><span class="ok">#{@summary['passed']}/#{@summary['total']} pass</span> <span class="bad">#{@summary['failed']} fail</span></span>
          <input id="q" type="search" placeholder="поиск по имени…">
          <span class="seg">
            <button type="button" data-f="all" class="active">все</button><button type="button" data-f="fail">провалы</button><button type="button" data-f="pass">ок</button>
          </span>
          <span class="seg">
            <button type="button" data-m="side" class="active">рядом</button><button type="button" data-m="slider">слайдер</button><button type="button" data-m="blink">мигание</button>
          </span>
          <span class="seg">
            <button type="button" data-h="on" class="active" aria-pressed="true">зоны</button>
          </span>
          <span class="hint">n/p — навигация · ⧉ — копировать путь</span>
        </header>
        #{groups}
        </body><script>#{JS}</script></html>
      HTML
    end

    def groups
      @summary["results"]
        .group_by { |r| File.dirname(r["rel"]) }
        .sort.map { |dir, results| group(dir, results) }.join
    end

    def group(dir, results)
      title = dir == "." ? "(root)" : dir
      <<~HTML
        <section class="group" data-dir="#{esc dir}">
          <h2>#{esc title}<span class="gcount">#{results.size}</span></h2>
          #{results.map { |r| shot(r) }.join}
        </section>
      HTML
    end

    def shot(result)
      rel = result["rel"]
      body = if result["image"]
               image_pair(result)
             elsif result["diff"]
               text_diff(result)
             else
               %(<p class="note">#{esc result['detail']}</p>)
             end
      diff_link = if result["diff_image"]
                    %( <a href="#{esc result['diff_image']}">diff</a>)
                  else
                    ""
                  end
      "<div class=\"shot #{result['status']}\" data-name=\"#{esc rel}\">" \
        "<h3>#{esc rel}<span class=\"badge\">#{esc result['kind']}</span>#{copy_buttons(result)}#{diff_link} " \
        "<span class=\"detail\">#{esc result['detail']}</span></h3>" \
        "#{body}</div>"
    end

    # Copy buttons carry the absolute snapshot path (per side) so it can be
    # pasted straight into an agent or a shell. Structure rows have only one side.
    def copy_buttons(result)
      rel = result["rel"]
      if result["kind"] == "structure"
        label, root = result["detail"].start_with?("missing") ? ["oracle", @config.oracle_path] : ["current", @config.current_path]
        copy_button(label, File.join(root, rel))
      else
        copy_button("oracle", File.join(@config.oracle_path, rel)) +
          copy_button("current", File.join(@config.current_path, rel))
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
            <figcaption>current</figcaption>
            <div class="imgwrap"><img loading="lazy" src="#{esc current_src}" alt="current">#{heat}</div>
          </figure>
        </div>
      HTML
    end

    # Purple overlay marking divergence zones: one positioned <i> per heat
    # cell, opacity scaled by the cell's intensity. Percent-based sizing
    # keeps it glued to the image in every display mode.
    def heat_layer(heat)
      return "" unless heat

      cells = heat["cells"].map do |col, row, intensity|
        left = col * heat["cell"].fdiv(heat["w"]) * 100
        top = row * heat["cell"].fdiv(heat["h"]) * 100
        width = [heat["cell"], heat["w"] - col * heat["cell"]].min.fdiv(heat["w"]) * 100
        height = [heat["cell"], heat["h"] - row * heat["cell"]].min.fdiv(heat["h"]) * 100
        alpha = (0.15 + 0.5 * intensity).round(2)
        %(<i style="left:#{left.round(2)}%;top:#{top.round(2)}%;width:#{width.round(2)}%;height:#{height.round(2)}%;background:rgba(160,32,240,#{alpha})"></i>)
      end.join
      %(<div class="heat" aria-hidden="true">#{cells}</div>)
    end

    def text_diff(result)
      rel = result["rel"]
      lines = result["diff"].map { |e| %(<span class="#{e['t']}">#{esc e['text']}</span>) }.join
      <<~HTML
        <pre class="diff">#{lines}</pre>
        <p class="note">оригиналы: <a href="#{esc File.join(@oracle_prefix, rel)}">oracle</a> · <a href="#{esc File.join(@current_prefix, rel)}">current</a></p>
      HTML
    end

    CSS = <<~'CSS'
      body{font:14px system-ui,sans-serif;margin:0;background:#d9e2ec}
      #topbar{position:sticky;top:0;z-index:30;display:flex;gap:14px;align-items:center;background:linear-gradient(135deg,#ffffff 0%,#cfe6ff 100%);border-bottom:3px solid #1976d2;padding:10px 14px;white-space:nowrap;box-shadow:0 2px 6px rgba(13,71,161,.25)}
      #topbar b{font-size:15px;color:#0d47a1}
      #q{width:220px;padding:3px 8px;border:1px solid #64b5f6;border-radius:3px;background:#fff}
      #stats .ok{color:#fff;background:#2e7d32;padding:1px 6px;border-radius:3px}
      #stats .bad{color:#fff;background:#d32f2f;padding:1px 6px;border-radius:3px}
      .seg button{border:1px solid #64b5f6;background:#fff;color:#0d47a1;padding:3px 10px;cursor:pointer;font-weight:600}
      .seg button.active{background:linear-gradient(135deg,#1976d2,#42a5f5);color:#fff;border-color:#1976d2}
      .hint{color:#456;font-size:12px}
      .group{margin:14px 0 0}
      .group h2{position:sticky;top:43px;z-index:20;margin:0;padding:6px 14px;font:600 13px ui-monospace,monospace;color:#0d47a1;background:linear-gradient(180deg,#e3f2fd,#bbdefb);border-top:2px solid #1976d2;border-bottom:1px solid #90caf9}
      .gcount{float:right;color:#28405e;font-weight:700}
      .shot{background:#fff;margin:0 0 12px;border:2px solid #90caf9;border-radius:6px}
      .shot.fail{border-color:#e53935}
      .shot h3{position:sticky;top:71px;z-index:10;margin:0;padding:6px 14px;font:600 13px ui-monospace,monospace;background:linear-gradient(180deg,#ffffff,#f0f7ff);border-bottom:2px solid #bbdefb}
      .shot.fail h3{background:linear-gradient(180deg,#fff5f5,#ffe3e3);border-bottom-color:#ef9a9a}
      .shot .badge{font:600 10px system-ui;color:#0d47a1;border:1px solid #64b5f6;padding:0 4px;margin-left:8px;vertical-align:1px;border-radius:3px;background:#e3f2fd}
      .shot .detail{color:#555;font-weight:400}
      .shot a{color:#0d47a1}
      .copy{font:600 10px system-ui;color:#0d47a1;background:#e3f2fd;border:1px solid #64b5f6;border-radius:3px;padding:1px 6px;cursor:pointer;margin-left:6px;vertical-align:1px}
      .copy:hover{background:#bbdefb}
      .copy.done{background:#2e7d32;border-color:#2e7d32;color:#fff}
      .pair{display:flex;--cut:50%}
      body[data-mode=slider] .pair,body[data-mode=blink] .pair{display:block;position:relative}
      .pair figure{flex:1 1 50%;min-width:0;margin:0}
      .pair figure+figure{border-left:5px solid #1976d2}
      .pair figcaption{padding:5px 10px;font:700 12px ui-monospace,monospace;color:#0d47a1;background:linear-gradient(180deg,#f5faff,#dbeeff);border-bottom:2px solid #90caf9}
      .imgwrap{position:relative}
      .pair img{display:block;width:100%;height:auto}
      .overlay{display:none}
      body[data-mode=slider] .overlay,body[data-mode=blink] .overlay{display:block;position:absolute;top:0;left:0;width:100%;height:auto}
      body[data-mode=slider] .overlay{clip-path:inset(0 calc(100% - var(--cut)) 0 0)}
      body[data-mode=blink] .overlay{animation:blink 1s steps(1) infinite}
      body[data-mode=slider] .side-b,body[data-mode=blink] .side-b{display:none}
      .heat{position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none}
      .heat i{position:absolute;display:block}
      body[data-heat=off] .heat{display:none}
      @keyframes blink{0%,50%{opacity:1}50.01%,100%{opacity:0}}
      .slider{display:none;width:100%}
      body[data-mode=slider] .slider{display:block}
      pre.diff{margin:0;padding:8px 0;font:12px/1.45 ui-monospace,monospace;overflow:auto;max-height:480px;background:#fbfdff}
      pre.diff span{display:block;padding:0 10px;white-space:pre}
      pre.diff .del{background:#ffd7d5}
      pre.diff .add{background:#d3f8d0}
      pre.diff .same{color:#777}
      .note{padding:6px 14px;color:#456;border-top:1px solid #e3f2fd}
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
            var count = g.querySelector('.gcount');
            if (count) count.textContent = shown + '/' + shots.length;
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
