/**
 * dsh-snip — 客户端半边
 *
 * 输入框旁放一个「📸 截图」按钮：点击 → 宿主拉起全屏框选遮罩（DSH 窗口
 * 自动暂时隐藏）→ 拖框选区 / ESC 取消 → PNG 落盘 + 图片进剪贴板。
 * 网页安全沙箱不允许插件替用户按 Ctrl+V，所以完成后提示「Ctrl+V 粘贴」。
 *
 * 三条纪律：fail-open（路由不通只提示）、绝不注入消息、只动自己的 DOM（dsn-*）。
 */
window.__ModuleLoader__.load({
  id: "dsh-snip",
  factory: function (require) {
    var module = { exports: {} };
    var exports = module.exports;

    var React = require("react");

    var PACKAGE_ID = "dsh-snip";
    var SLOT_NAME = "conversation.input.right";
    var ENTRY_ID = "snip-button";
    var ENTRY_ORDER = 72;
    var STYLE_MARKER = PACKAGE_ID;
    var ROUTE = "/dsh-snip";
    var HIDE_KEY = "dsn-hide-window";   // localStorage：「截图时隐藏 DSH 窗口」开关（QQ 同款）

    /* ══════════════════════ 样式 ══════════════════════ */

    var CSS = [
      ".dsn-root{display:inline-flex;align-items:center;min-width:0;position:relative}",
      ".dsn-btn{display:inline-flex;align-items:center;gap:4px;height:28px;padding:0 10px;border-radius:999px;"
        + "border:1px solid var(--dsw-alias-border-l1,rgba(15,17,21,.12));background:transparent;"
        + "color:var(--dsw-alias-label-primary,#0f1115);font-size:12px;line-height:1;cursor:pointer;"
        + "user-select:none;-webkit-user-select:none;white-space:nowrap}",
      ".dsn-btn:hover,.dsn-btn:focus-visible{border-color:var(--dsw-alias-state-business-primary,#4d93f8);"
        + "color:var(--dsw-alias-state-business-primary,#4d93f8)}",
      ".dsn-btn:focus-visible{outline:var(--dsw-focus-ring-width,2px) solid var(--dsw-focus-ring-color,#4d93f8);outline-offset:2px}",
      ".dsn-btn:disabled{opacity:.55;cursor:default}",
      ".dsn-caret{display:inline-flex;align-items:center;justify-content:center;height:28px;padding:0 7px;margin-left:2px;"
        + "border-radius:999px;border:1px solid var(--dsw-alias-border-l1,rgba(15,17,21,.12));background:transparent;"
        + "color:var(--dsw-alias-label-primary,#0f1115);font-size:10px;line-height:1;cursor:pointer;user-select:none}",
      ".dsn-caret:hover{border-color:var(--dsw-alias-state-business-primary,#4d93f8);color:var(--dsw-alias-state-business-primary,#4d93f8)}",
      ".dsn-menu{position:absolute;bottom:36px;right:0;background:rgba(20,22,30,.97);border:1px solid rgba(255,255,255,.08);"
        + "border-radius:10px;padding:4px;min-width:200px;box-shadow:0 8px 28px rgba(0,0,0,.35);z-index:2147483600}",
      ".dsn-item{display:flex;align-items:center;gap:8px;width:100%;padding:8px 12px;border:0;background:transparent;"
        + "color:#e8ecf5;font-size:12px;line-height:1.3;text-align:left;cursor:pointer;border-radius:6px;white-space:nowrap}",
      ".dsn-item:hover{background:rgba(77,147,248,.18)}",
      ".dsn-check{width:16px;display:inline-block;text-align:center}",
      ".dsn-toast{position:fixed;left:50%;bottom:96px;transform:translateX(-50%);background:rgba(15,17,21,.9);"
        + "color:#fff;padding:9px 16px;border-radius:10px;font-size:12px;z-index:2147483600;pointer-events:none;"
        + "max-width:70vw;text-align:center;box-shadow:0 6px 24px rgba(0,0,0,.25);transition:opacity .35s}",
      ".dsn-toast.dsn-ok{background:rgba(28,120,70,.94)}",
      ".dsn-toast.dsn-err{background:rgba(160,40,40,.94)}",
      ".dsn-toast-out{opacity:0}",
    ];

    function installStyles() {
      try {
        if (typeof document === "undefined" || !document.head) return null;
        var existing = document.querySelector('style[data-plugin-css="' + STYLE_MARKER + '"]');
        if (existing) return existing;
        var style = document.createElement("style");
        style.setAttribute("data-plugin-css", STYLE_MARKER);
        style.textContent = CSS.join("");
        document.head.appendChild(style);
        return style;
      } catch {
        return null;
      }
    }

    function showToast(message, kind, ms) {
      try {
        var t = document.createElement("div");
        t.className = "dsn-toast" + (kind ? " dsn-" + kind : "");
        t.textContent = message;
        document.body.appendChild(t);
        window.setTimeout(function () {
          t.classList.add("dsn-toast-out");
        }, ms || 3200);
        window.setTimeout(function () {
          if (t.parentNode) t.parentNode.removeChild(t);
        }, (ms || 3200) + 400);
      } catch {
        /* 提示失败就失败吧 */
      }
    }

    /* ══════════════════════ 组件 ══════════════════════ */

    function readHidePref() {
      try {
        var v = window.localStorage.getItem(HIDE_KEY);
        return v === null ? true : v === "1";   // 默认开启（默认不把 DSH 自己截进去）
      } catch (e) {
        return true;
      }
    }

    function writeHidePref(on) {
      try {
        window.localStorage.setItem(HIDE_KEY, on ? "1" : "0");
      } catch (e) {
        /* 存不了就本次会话内生效 */
      }
    }

    function SnipWidget() {
      var busyR = React.useState(false);
      var busy = busyR[0], setBusy = busyR[1];
      var hideR = React.useState(readHidePref());
      var hideOn = hideR[0], setHideOn = hideR[1];
      var menuR = React.useState(false);
      var menuOpen = menuR[0], setMenuOpen = menuR[1];
      var rootRef = React.useRef(null);

      // 菜单打开时点外面就收起（点在组件内不收，避免误关）
      React.useEffect(function () {
        if (!menuOpen) return undefined;
        var close = function (ev) {
          try {
            if (rootRef.current && ev.target && rootRef.current.contains(ev.target)) return;
          } catch (e) { /* 老浏览器无 contains 就直接收 */ }
          setMenuOpen(false);
        };
        document.addEventListener("mousedown", close);
        return function () {
          document.removeEventListener("mousedown", close);
        };
      }, [menuOpen]);

      function toggleHide() {
        var next = !readHidePref();
        writeHidePref(next);
        setHideOn(next);
        showToast(next ? "已开启：截图时隐藏 DSH 窗口" : "已关闭：截图时保留 DSH 窗口", "", 2400);
      }

      function startSnip() {
        if (busy) return;
        setBusy(true);
        setMenuOpen(false);
        // hide 走 URL 参数（最可靠）+ body 双通道，宿主任一侧解析成功即可
        fetch(ROUTE + "/start?hide=" + (hideOn ? "1" : "0"), {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ hideWindow: hideOn }),
        })
          .then(function (r) {
            return r.json();
          })
          .then(function (body) {
            if (!body || body.ok === false) {
              showToast("截图启动失败：" + (body && body.error ? body.error : "未知错误"), "err", 5000);
              setBusy(false);
              return;
            }
            showToast("框选模式已启动：拖框选区，ESC 取消", "", 2600);
            pollStatus(0);
          })
          .catch(function (error) {
            showToast("截图启动失败：" + String(error), "err", 5000);
            setBusy(false);
          });
      }

      function pollStatus(attempt) {
        if (attempt > 230) {
          showToast("截图超时（拖选太久无完成信号）", "err", 4000);
          setBusy(false);
          return;
        }
        fetch(ROUTE + "/status", { headers: { Accept: "application/json" } })
          .then(function (r) {
            return r.json();
          })
          .then(function (body) {
            var state = body && body.state ? body.state : { status: "running" };
            if (state.status === "running" || state.status === "idle") {
              // idle = 截图进行中但脚本尚未写完成状态，继续等（0.6s 一拍，
              // 截完的提示延迟最多 0.6s，太密会让 webServer 请求排队）
              window.setTimeout(function () {
                pollStatus(attempt + 1);
              }, 600);
              return;
            }
            if (state.status === "done") {
              // exe 会在恢复 DSH 前台后 ~0.8s 发一次真实 Ctrl+V（QQ 式自动粘贴）；
              // 这里把焦点放回输入框，粘贴才能落进正确的位置
              try {
                var candidates = document.querySelectorAll('textarea, [contenteditable="true"]');
                for (var k = candidates.length - 1; k >= 0; k--) {
                  var el = candidates[k];
                  var rect = el.getBoundingClientRect();
                  if (rect.width > 40 && rect.height > 20) { el.focus(); break; }
                }
              } catch (e) {
                /* 聚焦失败也不影响剪贴板里的图 */
              }
              showToast(
                "✅ 截图完成（" + (state.width || "?") + "×" + (state.height || "?") + "），正在自动粘贴——若没贴上按 Ctrl+V",
                "ok",
                6000,
              );
            } else if (state.status === "cancelled") {
              showToast("已取消截图", "", 1800);
            } else {
              showToast("截图失败：" + (state.error || "未知原因"), "err", 5000);
            }
            setBusy(false);
          })
          .catch(function () {
            // 状态查询偶发失败：继续轮询
            window.setTimeout(function () {
              pollStatus(attempt + 1);
            }, 1500);
          });
      }

      return React.createElement(
        "span",
        { className: "dsn-root", ref: rootRef },
        React.createElement(
          "button",
          {
            className: "dsn-btn",
            type: "button",
            disabled: busy,
            "aria-label": "快速截图",
            title: "快速截图：拖框选区 / 点一下选中整窗，截完自动粘贴",
            onClick: startSnip,
          },
          busy ? "⏳ 截图中…" : "📸 截图",
        ),
        React.createElement(
          "button",
          {
            className: "dsn-caret",
            type: "button",
            "aria-label": "截图选项",
            title: "截图选项",
            onClick: function () { setMenuOpen(!menuOpen); },
          },
          "▾",
        ),
        menuOpen
          ? React.createElement(
              "div",
              { className: "dsn-menu" },
              React.createElement(
                "button",
                { className: "dsn-item", type: "button", onClick: startSnip },
                React.createElement("span", { className: "dsn-check" }, "📷"),
                React.createElement("span", null, "开始截图"),
              ),
              React.createElement(
                "button",
                { className: "dsn-item", type: "button", onClick: toggleHide },
                React.createElement("span", { className: "dsn-check" }, hideOn ? "✓" : ""),
                React.createElement("span", null, "截图时隐藏 DSH 窗口"),
              ),
            )
          : null,
      );
    }

    /* ══════════════════════ 插槽注册 ══════════════════════ */

    function apply(ctx) {
      installStyles();
      try {
        ctx.slots.inject(SLOT_NAME, function () {
          return ctx.slots.register(
            {
              name: SLOT_NAME,
              id: ENTRY_ID,
              order: ENTRY_ORDER,
              label: function () { return "Quick screenshot"; },
            },
            function SlotComponent(props) {
              return React.createElement(SnipWidget, Object.assign({}, props, {}));
            },
          );
        });
      } catch (error) {
        try {
          console.error("[" + PACKAGE_ID + "] 插槽注册失败，按钮不会出现：", error);
        } catch (e) {
          /* 忽略 */
        }
      }
    }

    var inject = ["slots"];

    exports.apply = apply;
    exports.inject = inject;
    exports.__internals = { PACKAGE_ID: PACKAGE_ID, SLOT_NAME: SLOT_NAME, ENTRY_ID: ENTRY_ID, ROUTE: ROUTE };

    return module.exports;
  },
});
