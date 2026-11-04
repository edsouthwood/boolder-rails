// Admin pages switch Turbo off (data-turbo="false" on <body>), and with it Turbo's
// data-turbo-confirm prompts and data-turbo-method links. This does both for elements
// Turbo isn't handling, so "Delete" buttons ask first and delete links really DELETE.

const turboOff = (element) => element?.closest('[data-turbo]')?.dataset.turbo === 'false'

document.addEventListener('submit', (event) => {
  const form = event.target
  const submitter = event.submitter
  if (!turboOff(submitter || form)) return

  const message = submitter?.dataset.turboConfirm || form.dataset.turboConfirm
  if (message && !window.confirm(message)) {
    event.preventDefault()
    event.stopImmediatePropagation()
  }
}, true)

document.addEventListener('click', (event) => {
  const link = event.target.closest?.('a[data-turbo-confirm], a[data-turbo-method]')
  if (!link || !turboOff(link)) return

  const message = link.dataset.turboConfirm
  if (message && !window.confirm(message)) {
    event.preventDefault()
    event.stopImmediatePropagation()
    return
  }

  const method = (link.dataset.turboMethod || 'get').toLowerCase()
  if (method === 'get') return

  event.preventDefault()
  const form = document.createElement('form')
  form.method = 'post'
  form.action = link.href
  form.hidden = true
  const field = (name, value) => {
    const input = document.createElement('input')
    input.type = 'hidden'
    input.name = name
    input.value = value
    form.append(input)
  }
  field('_method', method)
  const token = document.querySelector('meta[name="csrf-token"]')?.content
  if (token) field(document.querySelector('meta[name="csrf-param"]')?.content || 'authenticity_token', token)
  document.body.append(form)
  form.submit()
}, true)
