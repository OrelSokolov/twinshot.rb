# frozen_string_literal: true

require "cgi/escape"
require "fileutils"
require "json"
require "pathname"

module Twinshot
  # Self-contained HTML report: 1:1 gallery grouped by directory, with search,
  # status filters and image compare modes (side-by-side / slider / blink).
  # CSS and JS are inlined; screenshots are referenced by relative paths.
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
        <body data-filter="all" data-mode="side">
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
          <span class="hint">n/p — навигация</span>
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
               image_pair(rel)
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
        "<h3>#{esc rel}<span class=\"badge\">#{esc result['kind']}</span>#{diff_link} " \
        "<span class=\"detail\">#{esc result['detail']}</span></h3>" \
        "#{body}</div>"
    end

    def image_pair(rel)
      oracle_src = "#{@oracle_prefix}/#{rel}"
      current_src = "#{@current_prefix}/#{rel}"
      <<~HTML
        <div class="pair">
          <figure class="side-a">
            <figcaption>oracle</figcaption>
            <div class="imgwrap">
              <img loading="lazy" src="#{esc oracle_src}" alt="oracle">
              <img loading="lazy" class="overlay" src="#{esc current_src}" alt="current">
            </div>
            <input class="slider" type="range" min="0" max="100" value="50" aria-label="compare slider">
          </figure>
          <figure class="side-b">
            <figcaption>current</figcaption>
            <img loading="lazy" src="#{esc current_src}" alt="current">
          </figure>
        </div>
      HTML
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
      body{font:14px system-ui,sans-serif;margin:0;background:#eee}
      #topbar{position:sticky;top:0;z-index:30;display:flex;gap:14px;align-items:center;background:#fff;border-bottom:1px solid #bbb;padding:10px 14px;white-space:nowrap}
      #topbar b{font-size:15px}
      #q{width:220px;padding:3px 8px}
      #stats .ok{color:#060}
      #stats .bad{color:#fff;background:#c00;padding:1px 6px;border-radius:3px}
      .seg button{border:1px solid #bbb;background:#fff;padding:3px 10px;cursor:pointer}
      .seg button.active{background:#333;color:#fff}
      .hint{color:#888;font-size:12px}
      .group{margin:14px 0 0}
      .group h2{position:sticky;top:41px;z-index:20;margin:0;padding:6px 14px;font:600 13px ui-monospace,monospace;background:#ddd;border-top:1px solid #ccc}
      .gcount{float:right;color:#444;font-weight:400}
      .shot{background:#fff;margin:0 0 10px}
      .shot h3{position:sticky;top:69px;z-index:10;margin:0;padding:6px 14px;font:600 13px ui-monospace,monospace;border-bottom:1px solid #e5e5e5}
      .shot.fail h3{background:#fdd}
      .shot .badge{font:600 10px system-ui;color:#666;border:1px solid #ccc;padding:0 4px;margin-left:8px;vertical-align:1px}
      .shot .detail{color:#555;font-weight:400}
      .shot a{color:#03c}
      .pair{display:flex;--cut:50%}
      body[data-mode=slider] .pair,body[data-mode=blink] .pair{display:block;position:relative}
      .pair figure{flex:1 1 50%;min-width:0;margin:0}
      .pair figure+figure{border-left:1px solid #ccc}
      .pair figcaption{padding:4px 10px;font:600 12px ui-monospace,monospace;background:#fafafa;border-bottom:1px solid #eee}
      .imgwrap{position:relative}
      .pair img{display:block;width:100%;height:auto}
      .overlay{display:none}
      body[data-mode=slider] .overlay,body[data-mode=blink] .overlay{display:block;position:absolute;top:0;left:0;width:100%;height:auto}
      body[data-mode=slider] .overlay{clip-path:inset(0 calc(100% - var(--cut)) 0 0)}
      body[data-mode=blink] .overlay{animation:blink 1s steps(1) infinite}
      body[data-mode=slider] .side-b,body[data-mode=blink] .side-b{display:none}
      @keyframes blink{0%,50%{opacity:1}50.01%,100%{opacity:0}}
      .slider{display:none;width:100%}
      body[data-mode=slider] .slider{display:block}
      pre.diff{margin:0;padding:8px 0;font:12px/1.45 ui-monospace,monospace;overflow:auto;max-height:480px}
      pre.diff span{display:block;padding:0 10px;white-space:pre}
      pre.diff .del{background:#ffd7d5}
      pre.diff .add{background:#d3f8d0}
      pre.diff .same{color:#777}
      .note{padding:6px 14px;color:#555}
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

        document.addEventListener('input', function (e) {
          if (e.target.classList && e.target.classList.contains('slider')) {
            e.target.closest('.pair').style.setProperty('--cut', e.target.value + '%');
          }
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
