/*
 * Отрисовка схем mermaid и их просмотр в модальном окне.
 *
 * Версия mermaid зафиксирована намеренно: тема Material подгружает mermaid
 * плавающей мажорной версией, из-за чего очередной релиз может молча сломать
 * отрисовку схем на сайте. Здесь версия закреплена, а тема задаётся явно —
 * это же обеспечивает читаемость в тёмном оформлении.
 *
 * Клик по схеме открывает её увеличенной: масштаб колесом или щипком,
 * перетаскивание мышью, Esc — закрыть. Схема также открывается с клавиатуры
 * (Tab + Enter/Space).
 *
 * Деградация: если CDN с mermaid недоступен или загрузка зависла (например,
 * за корпоративным прокси) — читатель должен увидеть понятное сообщение и
 * исходный текст схемы, а не пустое место без единого слова.
 */
(function () {
  "use strict";

  var MERMAID_URL = "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs";
  var MERMAID_LOAD_TIMEOUT_MS = 7000;
  var OVERLAY_ID = "diagram-zoom-overlay";
  var mermaidPromise = null;
  var viewer = null;
  var paletteObserver = null;
  /* Поколение перерисовки: растёт на каждый renderAll(), чтобы устаревшие
   * асинхронные результаты (например, от предыдущей темы) не перетирали
   * актуально отрисованную схему при быстром двойном переключении темы. */
  var renderGeneration = 0;

  function isDark() {
    var scheme = document.body.getAttribute("data-md-color-scheme");
    return scheme === "slate";
  }

  function escapeHtml(str) {
    return str.replace(/[&<>]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c];
    });
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
    if (mermaidPromise) return mermaidPromise;

    var importPromise = import(MERMAID_URL).then(function (mod) {
      return mod.default;
    });
    var timeoutPromise = new Promise(function (resolve, reject) {
      setTimeout(function () {
        reject(new Error("mermaid load timeout"));
      }, MERMAID_LOAD_TIMEOUT_MS);
    });

    mermaidPromise = Promise.race([importPromise, timeoutPromise]).catch(function (err) {
      // не кэшируем неудачу — сеть могла отвиснуть, следующая перерисовка
      // (например, смена темы) должна получить шанс попробовать снова
      mermaidPromise = null;
      throw err;
    });
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
    overlay.setAttribute("aria-label", "Просмотр схемы");
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
    var closeBtn = overlay.querySelector('[data-dz="close"]');
    var scale = 1, tx = 0, ty = 0;
    var dragging = false, lastX = 0, lastY = 0, pinch = 0;
    var lastTrigger = null;

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
      // возвращаем фокус туда, откуда открыли модалку
      if (lastTrigger && typeof lastTrigger.focus === "function") {
        lastTrigger.focus();
      }
      lastTrigger = null;
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
      open: function (svgEl, trigger) {
        lastTrigger = trigger || null;
        canvas.textContent = "";
        canvas.appendChild(svgEl);
        reset();
        overlay.classList.add("dz-open");
        document.body.classList.add("dz-lock");
        // фокус сразу на кнопку закрытия — чтобы клавиатурный пользователь
        // не терял место на странице внутри модалки
        if (closeBtn) closeBtn.focus();
      },
      close: close
    };
  }

  function openBlock(block) {
    var svg = block.querySelector("svg");
    if (!svg) return;
    var clone = svg.cloneNode(true);
    clone.removeAttribute("width");
    clone.removeAttribute("height");
    clone.style.maxWidth = "none";
    clone.style.width = "min(92vw, 1700px)";
    clone.style.height = "auto";
    viewer.open(clone, block);
  }

  /* ---------- отрисовка ---------- */

  function showLoading(block) {
    block.classList.remove("dz-zoomable", "dz-failed");
    block.removeAttribute("tabindex");
    block.removeAttribute("role");
    block.innerHTML = '<p class="dz-loading">Загрузка схемы…</p>';
  }

  function showError(block, src) {
    block.classList.remove("dz-zoomable");
    block.classList.add("dz-failed");
    block.removeAttribute("tabindex");
    block.removeAttribute("role");
    block.innerHTML =
      '<p class="dz-error">Не удалось отрисовать схему. ' +
      "Исходник ниже.</p><pre>" + escapeHtml(src || "") + "</pre>";
  }

  function renderAll() {
    var blocks = Array.prototype.slice.call(document.querySelectorAll(".mermaid-src"));
    if (!blocks.length) return;

    renderGeneration += 1;
    var generation = renderGeneration;

    // сохраняем исходник и сразу показываем плейсхолдер — до готовности
    // схемы читатель не должен видеть пустое место
    blocks.forEach(function (block) {
      if (!block.dataset.src) {
        block.dataset.src = (block.textContent || "").trim();
      }
      showLoading(block);
    });

    loadMermaid().then(function (mermaid) {
      if (generation !== renderGeneration) return; // палитра успела смениться повторно

      mermaid.initialize(themeConfig());
      if (!viewer) viewer = Viewer(buildOverlay());

      blocks.forEach(function (block, i) {
        var src = block.dataset.src;
        if (!src) return;

        var id = "dz-mmd-" + generation + "-" + i + "-" + (isDark() ? "d" : "l");
        mermaid.render(id, src).then(function (res) {
          if (generation !== renderGeneration) return; // устаревший рендер — отбрасываем
          block.innerHTML = res.svg;
          block.classList.remove("dz-failed");
          block.classList.add("dz-zoomable");
          block.setAttribute("title", "Нажмите, чтобы открыть схему крупнее");
          block.setAttribute("tabindex", "0");
          block.setAttribute("role", "button");
          block.setAttribute("aria-label", "Открыть схему крупнее");
          if (!block.dataset.dzBound) {
            block.dataset.dzBound = "1";
            block.addEventListener("click", function () { openBlock(block); });
            block.addEventListener("keydown", function (e) {
              if (e.key === "Enter" || e.key === " " || e.key === "Spacebar") {
                e.preventDefault();
                openBlock(block);
              }
            });
          }
        }).catch(function (err) {
          if (generation !== renderGeneration) return;
          showError(block, src);
          if (window.console) console.warn("mermaid render failed", err);
        });
      });
    }).catch(function (err) {
      if (generation !== renderGeneration) return;
      // CDN недоступен либо загрузка зависла дольше таймаута — та же
      // деградация, что и при ошибке рендера одной схемы: сообщение и исходник
      blocks.forEach(function (block) {
        showError(block, block.dataset.src);
      });
      if (window.console) console.warn("mermaid load failed", err);
    });
  }

  /* Перерисовка при переключении светлой/тёмной темы. */
  function watchPalette() {
    if (paletteObserver) return; // уже наблюдаем — не плодить MutationObserver'ы
    var last = isDark();
    paletteObserver = new MutationObserver(function () {
      if (isDark() !== last) {
        last = isDark();
        renderAll();
      }
    });
    paletteObserver.observe(document.body, { attributes: true, attributeFilter: ["data-md-color-scheme"] });
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
