const defaultTheme = require('tailwindcss/defaultTheme')
const colors = require('tailwindcss/colors')

module.exports = {
  content: [
    './public/*.html',
    './app/helpers/**/*.rb',
    './app/javascript/**/*.js',
    './app/views/**/*.{erb,haml,html,slim}'
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Outfit', 'system-ui', ...defaultTheme.fontFamily.sans],
      },
      // bowda brand palette (granite greys). Grade and circuit colours live elsewhere.
      colors: {
        granite: { DEFAULT: '#33393D', dark: '#1F2326' },
        // DEFAULT added alongside Tailwind's own stone-50…950 scale, which is still used.
        stone: { ...colors.stone, DEFAULT: '#6F767A' },
        muted: '#5E6468',
        ground: '#F3F3F1',
        line: '#DEDFDC',
        photo: '#D5D8D9',
        'on-dark': { DEFAULT: '#DADDDF', muted: '#C9CDD0' },
      },
      maxWidth: {
        site: '1200px',
      },
      // `prose-granite`: article links in the brand colour (was prose-emerald)
      typography: {
        granite: {
          css: {
            '--tw-prose-links': '#33393D',
            '--tw-prose-invert-links': '#DADDDF',
          },
        },
      },
    },
  },
  plugins: [
    require('@tailwindcss/forms'),
    require('@tailwindcss/aspect-ratio'),
    require('@tailwindcss/typography'),
    require('@tailwindcss/container-queries'),
  ]
}
