// Playwright HTML reporter subclass that strips `steps` out of every test
// result before the report is written. Needed because bc-replay's default
// HTML report records every page.fill() argument as a step — including the
// replay user's password, which would otherwise end up in the public Pages
// site we publish for stakeholders.
const path = require("path");
const pkgDir = path.dirname(require.resolve("playwright/package.json"));
const HtmlMod = require(path.join(pkgDir, "lib", "reporters", "html.js"));
const Html = HtmlMod.default || HtmlMod;

function clearSteps(suite) {
  for (const t of (suite.tests || [])) {
    for (const r of (t.results || [])) r.steps = [];
  }
  for (const c of (suite.suites || [])) clearSteps(c);
}

class StripStepsHtmlReporter extends Html {
  async onEnd(result) {
    if (this.suite) clearSteps(this.suite);
    return super.onEnd(result);
  }
}

module.exports = StripStepsHtmlReporter;
