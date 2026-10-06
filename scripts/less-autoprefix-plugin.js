/* eslint-disable @typescript-eslint/no-var-requires */

const autoprefixer = require("autoprefixer");
const postcss = require("postcss");

/**
 * Less post-processor that runs Autoprefixer (PostCSS 8+) on compiled CSS.
 * Replaces less-plugin-autoprefix, which pinned PostCSS 6 / Autoprefixer 8.
 */
class LessAutoprefixPlugin {
  install(_less, pluginManager) {
    pluginManager.addPostProcessor(
      {
        process(css) {
          return postcss([autoprefixer()]).process(css, { from: undefined }).css;
        },
      },
      2000
    );
  }
}

module.exports = LessAutoprefixPlugin;
