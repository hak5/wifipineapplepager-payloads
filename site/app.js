document.addEventListener('DOMContentLoaded', () => {
    const grid = document.getElementById('script-grid');

    // 1. Fetch the data from your JSON file
    fetch('payloads.json')
        .then(response => response.json())
        .then(scripts => {
            
            // 2. Iterate through each script in the database
            scripts.forEach(script => {
                const card = createCard(script);
                grid.appendChild(card);
            });

        })
        .catch(error => console.error('Error loading scripts:', error));
});

// Helper function to build the HTML for a single card
function createCard(script) {
    const article = document.createElement('article');
    article.classList.add('card');

    // Generate Tag HTML
    const tagsHtml = script.tags.map(tag => `<span>${tag}</span>`).join('');

    article.innerHTML = `
        <header>
            <h2>${script.title}</h2>
            <div class="tags">${tagsHtml}</div>
        </header>
        
        <p>${script.description}</p>
        
        <div class="actions">
            <a href="${script.download_url}" target="_blank" class="download-btn">
                Download Script
            </a>

            <div 
                data-lyket-type="upvote" 
                data-lyket-id="${script.vote_id}" 
                data-lyket-namespace="community-scripts"
                data-lyket-color-primary="#22c55e"
                data-lyket-font-family="sans-serif"
            ></div>
        </div>
    `;

    return article;
}