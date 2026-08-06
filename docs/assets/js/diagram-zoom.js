/*
 * Отрисовка схем mermaid и их просмотр в модальном окне.
 *
 * Версия mermaid зафиксирована намеренно: тема Material подгружает mermaid
 * плавающей мажорной версией, из-за чего очередной релиз может молча сломать
 * отрисовку схем на сайте. Здесь версия закреплена, а тема задаётся явно —
 * это же обеспечивает читаемость в тёмном оформлении.
 *
 * Клик по схеме открывает её увеличенной: масштаб колесом или щипком,
 * перетаскивание мышью, Esc — закрыть.
 */
(function () {
  "use strict";

  var MERMAID_URL = "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs";
  var OVERLAY_ID = "diagram-zoom-overlay";
  var mermaidPromise = null;
  var viewer = null;

  function isDark() {
    var scheme = document.body.getAttribute("data-md-color-scheme");
    return scheme === "slate";
  }

  /* Явная палитра: одинаково читаема на светлом и тёмном фоне. */
  function themeConfig() {
    var dark = isDark();
    return {
      startOnLoad: false,
      securityLevel: "strict",
      theme: "base",
      themeVariables: {
        background: dark ? "#1e2129" : "#ffffff",
        primaryColor: dark ? "#2a3142" : "#eef2ff",
        primaryTextColor: dark ? "#e6e9ef" : "#111827",
        primaryBorderColor: dark ? "#7c8cff" : "#2563eb",
        lineColor: dark ? "#9aa4bf" : "#4b5563",
        textColor: dark ? "#e6e9ef" : "#111827",
        secondaryColor: dark ? "#2b3550" : "#f3f4f6",
        tertiaryColor: dark ? "#242a36" : "#f9fafb",
        // подписи на стрелках — с подложкой, иначе сливаются с линиями
        edgeLabelBackground: dark ? "#1e2129" : "#ffffff",
        clusterBkg: dark ? "#232833" : "#f3f4f6",
        clusterBorder: dark ? "#4b5563" : "#d1d5db",
        actorBkg: dark ? "#2a3142" : "#eef2ff",
        actorTextColor: dark ? "#e6e9ef" : "#111827",
        actorBorder: dark ? "#7c8cff" : "#2563eb",
        signalColor: dark ? "#cbd2e1" : "#111827",
        signalTextColor: dark ? "#e6e9ef" : "#111827",
        labelBoxBkgColor: dark ? "#2a3142" : "#eef2ff",
        labelTextColor: dark ? "#e6e9ef" : "#111827",
        noteBkgColor: dark ? "#3a3320" : "#fef9c3",
        noteTextColor: dark ? "#f5e9c8" : "#111827"
      },
      flowchart: { htmlLabels: true, curve: "basis", useMaxWidth: true },
      sequence: { useMaxWidth: true, wrap: true }
    };
  }

  function loadMermaid() {
    if (!mermaidPromise) {
      mermaidPromise = import(MERMAID_URL).then(function (mod) {
        return mod.default;
      });
    }
    return mermaidPromise;
  }

  /* ---------- модальное окно ---------- */

  function buildOverlay() {
    var existing = document.getElementById(OVERLAY_ID);
    if (existing) return existing;
    var overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;
    overlay.className = "dz-overlay";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.innerHTML =
      '<div class="dz-toolbar">' +
      '<button type="button" class="dz-btn" data-dz="out" aria-label="Уменьшить">&minus;</button>' +
      '<button type="button" class="dz-btn" data-dz="reset" aria-label="Сбросить масштаб">100%</button>' +
      '<button type="button" class="dz-btn" data-dz="in" aria-label="Увеличить">&plus;</button>' +
      '<button type="button" class="dz-btn dz-close" data-dz="close" aria-label="Закрыть">&times;</button>' +
      "</div>" +
      '<div class="dz-stage"><div class="dz-canvas"></div></div>' +
      '<div class="dz-hint">Колесо или щипок — масштаб, перетаскивание — сдвиг, Esc — закрыть</div>';
    document.body.appendChild(overlay);
    return overlay;
  }

  function Viewer(overlay) {
    var canvas = overlay.querySelector(".dz-canvas");
    var stage = overlay.querySelector(".dz-stage");
    var scale = 1, tx = 0, ty = 0;
    var dragging = false, lastX = 0, lastY = 0, pinch = 0;

    function apply() {
      canvas.style.transform = "translate(" + tx + "px," + ty + "px) scale(" + scale + ")";
      var b = overlay.querySelector('[data-dz="reset"]');
      if (b) b.textContent = Math.round(scale * 100) + "%";
    }
    function setScale(next, ox, oy) {
      next = Math.min(8, Math.max(0.2, next));
      var r = stage.getBoundingClientRect();
      var cx = ox === undefined ? r.width / 2 : ox - r.left;
      var cy = oy === undefined ? r.height / 2 : oy - r.top;
      tx = cx - (cx - tx) * (next / scale);
      ty = cy - (cy - ty) * (next / scale);
      scale = next; apply();
    }
    function reset() { scale = 1; tx = 0; ty = 0; apply(); }
    function close() {
      overlay.classList.remove("dz-open");
      document.body.classList.remove("dz-lock");
      canvas.textContent = "";
    }

    stage.addEventListener("wheel", function (e) {
      e.preventDefault();
      setScale(scale * (e.deltaY < 0 ? 1.15 : 1 / 1.15), e.clientX, e.clientY);
    }, { passive: false });

    stage.addEventListener("mousedown", function (e) {
      dragging = true; lastX = e.clientX; lastY = e.clientY;
      stage.classList.add("dz-grabbing"); e.preventDefault();
    });
    window.addEventListener("mousemove", function (e) {
      if (!dragging) return;
      tx += e.clientX - lastX; ty += e.clientY - lastY;
      lastX = e.clientX; lastY = e.clientY; apply();
    });
    window.addEventListener("mouseup", function () {
      dragging = false; stage.classList.remove("dz-grabbing");
    });

    stage.addEventListener("touchstart", function (e) {
      if (e.touches.length === 1) {
        dragging = true; lastX = e.touches[0].clientX; lastY = e.touches[0].clientY;
      } else if (e.touches.length === 2) {
        dragging = false;
        pinch = Math.hypot(e.touches[0].clientX - e.touches[1].clientX,
                           e.touches[0].clientY - e.touches[1].clientY);
      }
    }, { passive: true });
    stage.addEventListener("touchmove", function (e) {
      if (e.touches.length === 1 && dragging) {
        tx += e.touches[0].clientX - lastX; ty += e.touches[0].clientY - lastY;
        lastX = e.touches[0].clientX; lastY = e.touches[0].clientY;
        apply(); e.preventDefault();
      } else if (e.touches.length === 2) {
        var d = Math.hypot(e.touches[0].clientX - e.touches[1].clientX,
                           e.touches[0].clientY - e.touches[1].clientY);
        if (pinch > 0) {
          setScale(scale * (d / pinch),
                   (e.touches[0].clientX + e.touches[1].clientX) / 2,
                   (e.touches[0].clientY + e.touches[1].clientY) / 2);
        }
        pinch = d; e.preventDefault();
      }
    }, { passive: false });
    stage.addEventListener("touchend", function () { dragging = false; pinch = 0; }, { passive: true });

    overlay.addEventListener("click", function (e) {
      var a = e.target.getAttribute && e.target.getAttribute("data-dz");
      if (a === "in") setScale(scale * 1.25);
      else if (a === "out") setScale(scale / 1.25);
      else if (a === "reset") reset();
      else if (a === "close" || e.target === stage || e.target === overlay) close();
    });
    document.addEventListener("keydown", function (e) {
      if (!overlay.classList.contains("dz-open")) return;
      if (e.key === "Escape") close();
      else if (e.key === "+" || e.key === "=") setScale(scale * 1.25);
      else if (e.key === "-") setScale(scale / 1.25);
      else if (e.key === "0") reset();
    });

    return {
      open: function (svgEl) {
        canvas.textContent = "";
        canvas.appendChild(svgEl);
        reset();
        overlay.classList.add("dz-open");
        document.body.classList.add("dz-lock");
      },
      close: close
    };
  }

  /* ---------- отрисовка ---------- */

  function renderAll() {
    var blocks = Array.prototype.slice.call(document.querySelectorAll(".mermaid-src"));
    if (!blocks.length) return;

    loadMermaid().then(function (mermaid) {
      mermaid.initialize(themeConfig());
      if (!viewer) viewer = Viewer(buildOverlay());

      blocks.forEach(function (block, i) {
        // исходник храним, чтобы можно было перерисовать при смене темы
        if (!block.dataset.src) {
          block.dataset.src = (block.textContent || "").trim();
        }
        var src = block.dataset.src;
        if (!src) return;

        var id = "dz-mmd-" + i + "-" + (isDark() ? "d" : "l");
        mermaid.render(id, src).then(function (res) {
          block.innerHTML = res.svg;
          block.classList.add("dz-zoomable");
          block.setAttribute("title", "Нажмите, чтобы открыть схему крупнее");
          if (!block.dataset.dzBound) {
            block.dataset.dzBound = "1";
            block.addEventListener("click", function () {
              var svg = block.querySelector("svg");
              if (!svg) return;
              var clone = svg.cloneNode(true);
              clone.removeAttribute("width");
              clone.removeAttribute("height");
              clone.style.maxWidth = "none";
              clone.style.width = "min(92vw, 1700px)";
              clone.style.height = "auto";
              viewer.open(clone);
            });
          }
        }).catch(function (err) {
          block.innerHTML =
            '<p class="dz-error">Не удалось отрисовать схему. ' +
            "Исходник ниже.</p><pre>" +
            src.replace(/[&<>]/g, function (c) {
              return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c];
            }) + "</pre>";
          if (window.console) console.warn("mermaid render failed", err);
        });
      });
    }).catch(function (err) {
      if (window.console) console.warn("mermaid load failed", err);
    });
  }

  /* Перерисовка при переключении светлой/тёмной темы. */
  function watchPalette() {
    var last = isDark();
    new MutationObserver(function () {
      if (isDark() !== last) {
        last = isDark();
        document.querySelectorAll(".mermaid-src").forEach(function (b) {
          b.classList.remove("dz-zoomable");
        });
        renderAll();
      }
    }).observe(document.body, { attributes: true, attributeFilter: ["data-md-color-scheme"] });
  }

  function boot() {
    renderAll();
    watchPalette();
  }

  if (typeof document$ !== "undefined" && document$.subscribe) {
    document$.subscribe(boot);
  } else if (document.readyState !== "loading") {
    boot();
  } else {
    document.addEventListener("DOMContentLoaded", boot);
  }
})();
