document.addEventListener('DOMContentLoaded', () => {
    
    // --- Theme Toggle Logic ---
    const themeBtn = document.getElementById('theme-toggle');
    const htmlEl = document.documentElement;

    // Check for saved preference
    const savedTheme = localStorage.getItem('theme') || 'light';
    htmlEl.setAttribute('data-theme', savedTheme);

    themeBtn.addEventListener('click', () => {
        const currentTheme = htmlEl.getAttribute('data-theme');
        const newTheme = currentTheme === 'light' ? 'dark' : 'light';
        
        htmlEl.setAttribute('data-theme', newTheme);
        localStorage.setItem('theme', newTheme);
    });
    // ---------------------------

    const grid = document.getElementById('script-grid');

    fetch('site/payloads.json')
        .then(response => response.json())
        .then(scripts => {
            scripts.forEach(script => {
                const card = createCard(script);
                grid.appendChild(card);
            });
        })
        .catch(error => console.error('Error loading scripts:', error));
});

function createCard(script) {
    const article = document.createElement('article');
    article.classList.add('card');

    const tagsHtml = script.tags.map(tag => `<span>${tag}</span>`).join('');

    article.innerHTML = `
        <header>
            <h2>${script.title}</h2>
            <div class="tags">${tagsHtml}</div>
        </header>
        
        <p>${script.description}</p>
        
        <div class="actions">
            <a href="${script.download_url}" target="_blank" class="download-btn">
                DOWNLOAD
            </a>

            <div 
                data-lyket-type="upvote" 
                data-lyket-id="${script.vote_id}" 
                data-lyket-namespace="community-scripts"
                data-lyket-color-primary="#EC2028"
                data-lyket-font-family="Open Sans"
            ></div>
        </div>
    `;

    return article;
}