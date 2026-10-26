(function () {
  const el = document.getElementById("env-banner");
  if (!el) return;
  const host = location.hostname || "";
  const path = location.pathname || "";
  // In-cluster Playground Route is playground-*. GitHub Pages uses /playground/.
  const playground =
    host.indexOf("playground-") === 0 || /(^|\/)playground(\/|$)/.test(path);
  const note = document.querySelector(".header-note");
  if (note) {
    note.textContent = playground
      ? "Playground · Red Hat OpenShift AI 3.5"
      : "Presenter · Red Hat OpenShift AI 3.5";
  }
  fetch("/env.json", { cache: "no-store" })
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error("no env"))))
    .then((env) => {
      const items = playground
        ? [
            ["Playground", env.playground, env.playground],
            ["OpenShift console", env.console, env.console],
            ["OpenShift AI", env.rhoai_dashboard, env.rhoai_dashboard],
            ["CPU workbench project", env.workbench_project, null],
            ["Playground A", env.ran_project, null],
            ["Playground B", env.core_project, null],
          ]
        : [
            ["Presenter guide", env.lab_guide, env.lab_guide],
            ["Playground (students)", env.playground, env.playground],
            ["OpenShift console", env.console, env.console],
            ["OpenShift AI", env.rhoai_dashboard, env.rhoai_dashboard],
            ["Open WebUI (presenter)", env.open_webui, env.open_webui],
            ["S4 demo object storage", env.s4, env.s4],
            ["Presenter project", env.presenter_project, null],
            ["CPU workbench project", env.workbench_project, null],
            ["Playground A", env.ran_project, null],
            ["Playground B", env.core_project, null],
          ];
      el.innerHTML =
        '<div class="env-grid">' +
        items
          .filter((row) => row[1])
          .map(([label, value, href]) => {
            const v = href
              ? '<a href="' + href + '" target="_blank" rel="noopener">' + value + "</a>"
              : value;
            return "<div><strong>" + label + ":</strong> " + v + "</div>";
          })
          .join("") +
        "</div>";
    })
    .catch(() => {
      el.textContent = playground
        ? "Playground URLs are not mounted yet. After setup, this banner shows the console and OpenShift AI dashboard. Call models with your Route and workshop-infer token."
        : "Lab environment URLs are not mounted yet. After setup, this banner shows the console, OpenShift AI dashboard, optional Open WebUI, and the student playground URL.";
    });
})();
