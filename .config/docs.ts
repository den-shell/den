import type { BunPressConfig } from 'bunpress'

const config: BunPressConfig = {
  name: 'Den Shell',
  description: 'A modern, high-performance shell written in Zig with native speed and memory safety',
  url: 'https://den.sh',

  nav: [
    { text: 'Guide', link: '/intro' },
    { text: 'Features', link: '/features/overview' },
    { text: 'Builtins', link: '/BUILTINS' },
    { text: 'Migration', link: '/BASH_MIGRATION' },
    { text: 'GitHub', link: 'https://github.com/stacksjs/den' },
  ],

  // One comprehensive sidebar (applies to every page) so every feature is
  // reachable from the docs navigation. Every link maps to a real file under ./docs.
  sidebar: {
    '/': [
      {
        text: 'Getting Started',
        items: [
          { text: 'Introduction', link: '/intro' },
          { text: 'Installation', link: '/install' },
          { text: 'Quick Start', link: '/guide/quick-start' },
          { text: 'Usage', link: '/usage' },
          { text: 'Configuration', link: '/config' },
          { text: 'Quick Reference', link: '/QUICK_REFERENCE' },
        ],
      },
      {
        text: 'Core Features',
        items: [
          { text: 'Overview', link: '/features/overview' },
          { text: 'Pipelines', link: '/features/pipelines' },
          { text: 'Redirections', link: '/features/redirections' },
          { text: 'Job Control', link: '/features/job-control' },
          { text: 'Expansions', link: '/features/expansions' },
          { text: 'Scripting', link: '/SCRIPTING' },
          { text: 'Builtins Reference', link: '/BUILTINS' },
          { text: 'Themes & Prompt', link: '/THEMES' },
        ],
      },
      {
        text: 'Interactive & Completion',
        items: [
          { text: 'Line Editing', link: '/LINE_EDITING' },
          { text: 'Tab Completion', link: '/TAB_COMPLETION' },
          { text: 'Autocompletion', link: '/AUTOCOMPLETION' },
          { text: 'Git Completion', link: '/GIT_COMPLETION' },
          { text: 'Mid-word Completion', link: '/MID_WORD_COMPLETION' },
          { text: 'History Substring Search', link: '/HISTORY_SUBSTRING_SEARCH' },
        ],
      },
      {
        text: 'Extending Den',
        items: [
          { text: 'Extended Features', link: '/EXTENDED_FEATURES' },
          { text: 'Custom Commands', link: '/guide/custom-commands' },
          { text: 'Custom Builtins & Plugins', link: '/advanced/custom-builtins' },
          { text: 'Plugin Development', link: '/PLUGIN_DEVELOPMENT' },
        ],
      },
      {
        text: 'Advanced',
        items: [
          { text: 'Advanced Usage', link: '/ADVANCED' },
          { text: 'Advanced Configuration', link: '/advanced/configuration' },
          { text: 'Shell Integration', link: '/advanced/shell-integration' },
          { text: 'Performance Tuning', link: '/advanced/performance' },
        ],
      },
      {
        text: 'Migration',
        items: [
          { text: 'Bash Migration', link: '/BASH_MIGRATION' },
          { text: 'zsh Compatibility', link: '/ZSH_MIGRATION' },
          { text: 'Migration Guide', link: '/MIGRATION' },
          { text: 'Troubleshooting', link: '/TROUBLESHOOTING' },
        ],
      },
      {
        text: 'Performance & Internals',
        items: [
          { text: 'Benchmarks', link: '/BENCHMARKS' },
          { text: 'Algorithms', link: '/ALGORITHMS' },
          { text: 'Data Structures', link: '/DATA_STRUCTURES' },
          { text: 'CPU Optimization', link: '/CPU_OPTIMIZATION' },
          { text: 'Memory Optimization', link: '/MEMORY_OPTIMIZATION' },
          { text: 'Concurrency', link: '/CONCURRENCY' },
          { text: 'Profiling', link: '/profiling' },
        ],
      },
      {
        text: 'Develop & Contribute',
        items: [
          { text: 'Architecture', link: '/ARCHITECTURE' },
          { text: 'API Reference', link: '/API' },
          { text: 'Testing', link: '/TESTING' },
          { text: 'CI/CD', link: '/CI_CD' },
          { text: 'Dependencies', link: '/DEPENDENCIES' },
          { text: 'Contributing', link: '/CONTRIBUTING' },
        ],
      },
    ],
  },

  themeConfig: {
    colors: {
      primary: '#10b981',
    },
  },
}

export default config
