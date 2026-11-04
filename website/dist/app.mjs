// Copy buttons for the Homebrew command. Everything else on the page is static.
const toast = document.getElementById('toast');
let timer;

function say(message) {
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(timer);
  timer = setTimeout(() => toast.classList.remove('show'), 2200);
}

for (const button of document.querySelectorAll('[data-copy]')) {
  button.addEventListener('click', async () => {
    const source = document.querySelector(button.dataset.copy);
    try {
      await navigator.clipboard.writeText(source.textContent.trim());
      button.textContent = 'Copied';
      setTimeout(() => { button.textContent = 'Copy'; }, 1800);
    } catch {
      say('Select the command and copy it.');
    }
  });
}
