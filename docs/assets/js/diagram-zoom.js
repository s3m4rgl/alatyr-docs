/*
 * Просмотр схем в модальном окне: клик по схеме открывает её увеличенной,
 * с масштабированием (колесо / щипок / кнопки) и перетаскиванием.
 * Без внешних зависимостей.
 */
(function () {
  "use strict";

  var OVERLAY_ID = "diagram-zoom-overlay";

  function buildOverlay() {
    var existing = document.getElementById(OVERLAY_ID);
    if (existing) return existing;

    var overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;
    overlay.className = "dz-overlay";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-label", "Схема в увеличенном виде");
    overlay.innerHTML =
      '<div class="dz-toolbar">' +
      '<button type="button" class="dz-btn" data-dz="out" aria-label="Уменьшить">&minus;</button>' +
      '<button type="button" class="dz-btn" data-dz="reset" aria-label="Сбросить масштаб">100%</button>' +
      '<button type="button" class="dz-btn" data-dz="in" aria-label="Увеличить">&plus;</button>' +
      '<button type="button" class="dz-btn dz-close" data-dz="close" aria-label="Закрыть">&times;</button>' +
      "</div>" +
      '<div class="dz-stage"><div class="dz-canvas"></div></div>' +
      '<div class="dz-hint">Колесо мыши или щипок — масштаб. Перетаскивание — сдвиг. Esc — закрыть.</div>';

    document.body.appendChild(overlay);
    return overlay;
  }

  function Viewer(overlay) {
    var canvas = overlay.querySelector(".dz-canvas");
    var stage = overlay.querySelector(".dz-stage");
    var scale = 1, tx = 0, ty = 0;
    var dragging = false, lastX = 0, lastY = 0, pinchDist = 0;

    function apply() {
      canvas.style.transform =
        "translate(" + tx + "px," + ty + "px) scale(" + scale + ")";
      var pct = overlay.querySelector('[data-dz="reset"]');
      if (pct) pct.textContent = Math.round(scale * 100) + "%";
    }

    function setScale(next, originX, originY) {
      next = Math.min(8, Math.max(0.2, next));
      var rect = stage.getBoundingClientRect();
      var cx = (originX === undefined ? rect.width / 2 : originX - rect.left);
      var cy = (originY === undefined ? rect.height / 2 : originY - rect.top);
      // Держим точку под курсором на месте при изменении масштаба.
      tx = cx - (cx - tx) * (next / scale);
      ty = cy - (cy - ty) * (next / scale);
      scale = next;
      apply();
    }

    function reset() {
      scale = 1; tx = 0; ty = 0; apply();
    }

    stage.addEventListener("wheel", function (e) {
      e.preventDefault();
      setScale(scale * (e.deltaY < 0 ? 1.15 : 1 / 1.15), e.clientX, e.clientY);
    }, { passive: false });

    stage.addEventListener("mousedown", function (e) {
      dragging = true; lastX = e.clientX; lastY = e.clientY;
      stage.classList.add("dz-grabbing");
      e.preventDefault();
    });
    window.addEventListener("mousemove", function (e) {
      if (!dragging) return;
      tx += e.clientX - lastX; ty += e.clientY - lastY;
      lastX = e.clientX; lastY = e.clientY;
      apply();
    });
    window.addEventListener("mouseup", function () {
      dragging = false; stage.classList.remove("dz-grabbing");
    });

    stage.addEventListener("touchstart", function (e) {
      if (e.touches.length === 1) {
        dragging = true;
        lastX = e.touches[0].clientX; lastY = e.touches[0].clientY;
      } else if (e.touches.length === 2) {
        dragging = false;
        pinchDist = Math.hypot(
          e.touches[0].clientX - e.touches[1].clientX,
          e.touches[0].clientY - e.touches[1].clientY
        );
      }
    }, { passive: true });

    stage.addEventListener("touchmove", function (e) {
      if (e.touches.length === 1 && dragging) {
        tx += e.touches[0].clientX - lastX;
        ty += e.touches[0].clientY - lastY;
        lastX = e.touches[0].clientX; lastY = e.touches[0].clientY;
        apply();
        e.preventDefault();
      } else if (e.touches.length === 2) {
        var d = Math.hypot(
          e.touches[0].clientX - e.touches[1].clientX,
          e.touches[0].clientY - e.touches[1].clientY
        );
        if (pinchDist > 0) {
          setScale(
            scale * (d / pinchDist),
            (e.touches[0].clientX + e.touches[1].clientX) / 2,
            (e.touches[0].clientY + e.touches[1].clientY) / 2
          );
        }
        pinchDist = d;
        e.preventDefault();
      }
    }, { passive: false });

    stage.addEventListener("touchend", function () {
      dragging = false; pinchDist = 0;
    }, { passive: true });

    overlay.addEventListener("click", function (e) {
      var act = e.target.getAttribute && e.target.getAttribute("data-dz");
      if (act === "in") setScale(scale * 1.25);
      else if (act === "out") setScale(scale / 1.25);
      else if (act === "reset") reset();
      else if (act === "close" || e.target === stage || e.target === overlay) close();
    });

    function open(svg) {
      canvas.innerHTML = "";
      canvas.appendChild(svg);
      reset();
      overlay.classList.add("dz-open");
      document.body.classList.add("dz-lock");
    }

    function close() {
      overlay.classList.remove("dz-open");
      document.body.classList.remove("dz-lock");
      canvas.innerHTML = "";
    }

    document.addEventListener("keydown", function (e) {
      if (!overlay.classList.contains("dz-open")) return;
      if (e.key === "Escape") close();
      else if (e.key === "+" || e.key === "=") setScale(scale * 1.25);
      else if (e.key === "-") setScale(scale / 1.25);
      else if (e.key === "0") reset();
    });

    return { open: open, close: close };
  }

  var viewer = null;

  function enhance() {
    if (!viewer) viewer = Viewer(buildOverlay());

    document.querySelectorAll(".mermaid").forEach(function (el) {
      if (el.dataset.dzReady === "1") return;
      var svg = el.querySelector("svg");
      if (!svg) return;             // mermaid ещё не отрисовал — попробуем позже
      el.dataset.dzReady = "1";
      el.classList.add("dz-zoomable");
      el.setAttribute("title", "Нажмите, чтобы открыть схему в увеличенном виде");
      el.addEventListener("click", function () {
        var clone = el.querySelector("svg").cloneNode(true);
        clone.removeAttribute("width");
        clone.removeAttribute("height");
        clone.style.maxWidth = "none";
        clone.style.width = "min(92vw, 1600px)";
        clone.style.height = "auto";
        viewer.open(clone);
      });
    });
  }

  function schedule() {
    // Схемы отрисовываются асинхронно — опрашиваем несколько раз.
    var tries = 0;
    var timer = setInterval(function () {
      enhance();
      if (++tries > 20) clearInterval(timer);
    }, 250);
    enhance();
  }

  if (typeof document$ !== "undefined" && document$.subscribe) {
    document$.subscribe(schedule);   // навигация Material без перезагрузки
  } else if (document.readyState !== "loading") {
    schedule();
  } else {
    document.addEventListener("DOMContentLoaded", schedule);
  }
})();
