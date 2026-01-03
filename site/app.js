document.addEventListener('DOMContentLoaded', () => {
    
    // --- Theme Toggle (Same as before) ---
    const themeBtn = document.getElementById('theme-toggle');
    const htmlEl = document.documentElement;
    const savedTheme = localStorage.getItem('theme') || 'light';
    htmlEl.setAttribute('data-theme', savedTheme);

    themeBtn.addEventListener('click', () => {
        const currentTheme = htmlEl.getAttribute('data-theme');
        const newTheme = currentTheme === 'light' ? 'dark' : 'light';
        htmlEl.setAttribute('data-theme', newTheme);
        localStorage.setItem('theme', newTheme);
    });
    // -------------------------------------

    const grid = document.getElementById('script-grid');
    const searchInput = document.getElementById('search-input');
    const categorySelect = document.getElementById('category-filter');
    const sortSelect = document.getElementById('sort-order');

    let allScripts = [];

    // Fetch and Initialize
    fetch('site/payloads.json')
        .then(response => response.json())
        .then(scripts => {
            allScripts = scripts;
            populateCategories(scripts);
            renderGrid(scripts); // Initial render
        })
        .catch(error => console.error('Error loading scripts:', error));

    // --- Event Listeners for Filters ---
    searchInput.addEventListener('input', handleFilterChange);
    categorySelect.addEventListener('change', handleFilterChange);
    sortSelect.addEventListener('change', handleFilterChange);

    function handleFilterChange() {
        const searchTerm = searchInput.value.toLowerCase();
        const selectedCategory = categorySelect.value;
        const sortMode = sortSelect.value;

        // 1. Filter
        let filtered = allScripts.filter(script => {
            const matchesSearch = 
                script.title.toLowerCase().includes(searchTerm) || 
                script.description.toLowerCase().includes(searchTerm) ||
                script.tags.some(tag => tag.toLowerCase().includes(searchTerm));
            
            const matchesCategory = selectedCategory === 'all' || script.category === selectedCategory;

            return matchesSearch && matchesCategory;
        });

        // 2. Sort
        filtered.sort((a, b) => {
            if (sortMode === 'votes') return b.votes - a.votes;
            if (sortMode === 'alpha') return a.title.localeCompare(b.title);
            // Assuming the JSON array order is "newest" by default if no date field exists
            return 0; 
        });

        renderGrid(filtered);
    }

    function populateCategories(scripts) {
        const categories = new Set(scripts.map(s => s.category).filter(c => c));
        categories.forEach(cat => {
            const option = document.createElement('option');
            option.value = cat;
            option.textContent = cat;
            categorySelect.appendChild(option);
        });
    }

    function renderGrid(scripts) {
        grid.innerHTML = ''; // Clear current grid
        
        if (scripts.length === 0) {
            grid.innerHTML = '<p class="no-results">No payloads found.</p>';
            return;
        }

        scripts.forEach(script => {
            const card = createCard(script);
            grid.appendChild(card);
        });
    }
});

function createCard(script) {
    const article = document.createElement('article');
    article.classList.add('card');

    const tagsHtml = script.tags.map(tag => `<span>${tag}</span>`).join('');
    
    // GitHub Issue URL for voting
    const repoBase = "https://github.com/YOUR_USERNAME/YOUR_REPO"; 
    const voteUrl = `${repoBase}/issues/${script.issue_number}`;

    article.innerHTML = `
        <header>
            <div class="meta-top">
                <span class="category-badge">${script.category || 'General'}</span>
            </div>
            <h2>${script.title}</h2>
            <div class="tags">${tagsHtml}</div>
        </header>
        
        <p>${script.description}</p>
        
        <div class="actions">
            <a href="${script.readme_url}" target="_blank" class="download-btn">
                VIEW README
            </a>

            <a href="${voteUrl}" target="_blank" class="vote-btn" title="Login to GitHub to vote">
                <span class="heart-icon">👍</span> 
                <span class="vote-count">${script.votes}</span>
            </a>
        </div>
    `;

    return article;
}