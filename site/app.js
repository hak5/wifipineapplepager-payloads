document.addEventListener('DOMContentLoaded', () => {
    console.log("App started...");

    // --- DOM Elements ---
    const grid = document.getElementById('script-grid');
    const searchInput = document.getElementById('search-input');
    const categorySelect = document.getElementById('category-filter');
    const tagSelect = document.getElementById('tag-filter'); // Ensure this ID exists in HTML
    const sortSelect = document.getElementById('sort-order');
    const themeBtn = document.getElementById('theme-toggle');

    // --- Theme Logic ---
    const htmlEl = document.documentElement;
    const savedTheme = localStorage.getItem('theme') || 'light';
    htmlEl.setAttribute('data-theme', savedTheme);

    themeBtn.addEventListener('click', () => {
        const currentTheme = htmlEl.getAttribute('data-theme');
        const newTheme = currentTheme === 'light' ? 'dark' : 'light';
        htmlEl.setAttribute('data-theme', newTheme);
        localStorage.setItem('theme', newTheme);
    });

    // --- Main Logic ---
    let allScripts = [];

    fetch('site/payloads.json')
        .then(response => {
            if (!response.ok) throw new Error("Failed to load JSON file");
            return response.json();
        })
        .then(scripts => {
            console.log("Payloads loaded:", scripts.length);
            
            // Filter out hidden scripts immediately
            allScripts = scripts.filter(s => s.visible !== false);
            
            // Populate Dropdowns
            populateCategories(allScripts);
            populateTags(allScripts); 

            // Initial Render
            handleFilterChange(); // <--- This forces the "Newest" sort to run immediately
        })
        .catch(error => console.error('Error loading scripts:', error));

    // --- Event Listeners ---
    if (searchInput) searchInput.addEventListener('input', handleFilterChange);
    if (categorySelect) categorySelect.addEventListener('change', handleFilterChange);
    if (tagSelect) tagSelect.addEventListener('change', handleFilterChange);
    if (sortSelect) sortSelect.addEventListener('change', handleFilterChange);

    // --- Functions ---

    function handleFilterChange() {
        const searchTerm = searchInput.value.toLowerCase();
        const selectedCategory = categorySelect.value;
        const selectedTag = tagSelect.value;
        const sortMode = sortSelect.value;

        // 1. Filter
        let filtered = allScripts.filter(script => {
            // Safety check for missing tags
            const scriptTags = script.tags || [];

            const matchesSearch = 
                (script.title || '').toLowerCase().includes(searchTerm) || 
                (script.description || '').toLowerCase().includes(searchTerm) ||
                scriptTags.some(tag => tag.toLowerCase().includes(searchTerm));
            
            const matchesCategory = selectedCategory === 'all' || script.category === selectedCategory;
            
            const matchesTag = selectedTag === 'all' || scriptTags.includes(selectedTag);

            return matchesSearch && matchesCategory && matchesTag;
        });

        // 2. Sort
        filtered.sort((a, b) => {
            if (sortMode === 'votes') return (b.votes || 0) - (a.votes || 0);
            if (sortMode === 'alpha') return (a.title || '').localeCompare(b.title || '');
            
            // --- NEWEST FILTER LOGIC ---
            // Convert strings (YYYY-MM-DD) to Date objects for correct math
            const dateA = new Date(a.last_updated || 0);
            const dateB = new Date(b.last_updated || 0);
            
            // Return B minus A for Descending order (Newest first)
            return dateB - dateA; 
        });

        renderGrid(filtered);
    }

    function populateCategories(scripts) {
        if (!categorySelect) return;
        const categories = new Set(scripts.map(s => s.category).filter(c => c));
        categories.forEach(cat => {
            const option = document.createElement('option');
            option.value = cat;
            option.textContent = cat;
            categorySelect.appendChild(option);
        });
    }

    function populateTags(scripts) {
        if (!tagSelect) {
            console.error("Tag select element not found!");
            return;
        }
        
        // 1. Flatten all tags
        const allTags = scripts.flatMap(s => s.tags || []);
        
        // 2. Unique & Sort
        const uniqueTags = [...new Set(allTags)].sort();
        console.log("Tags found:", uniqueTags); // Debug log

        // 3. Create Options
        uniqueTags.forEach(tag => {
            const option = document.createElement('option');
            option.value = tag;
            option.textContent = tag;
            tagSelect.appendChild(option);
        });
    }

    function formatDate(dateString) {
        if (!dateString) return '';
        const date = new Date(dateString);
        // Check if date is valid
        if (isNaN(date.getTime())) return dateString; 
        
        // Return MM/DD/YYYY
        return date.toLocaleDateString('en-US', {
            year: 'numeric',
            month: '2-digit',
            day: '2-digit'
        });
    }

    function renderGrid(scripts) {
        if (!grid) return;
        grid.innerHTML = ''; 
        
        if (scripts.length === 0) {
            grid.innerHTML = '<p class="no-results">No payloads found.</p>';
            return;
        }

        scripts.forEach(script => {
            const card = createCard(script);
            grid.appendChild(card);
        });
    }

    function createCard(script) {
        const article = document.createElement('article');
        article.classList.add('card');

        // Safety check for tags
        const tagsHtml = (script.tags || []).map(tag => `<span>${tag}</span>`).join('');
        
        // --- FIX 1: URL Construction ---
        // We look for 'readme_url' OR 'readme_path' to be safe
        const rawPath = script.readme_url || script.readme_path || ''; 
        
        // Remove leading slash if present
        const cleanPath = rawPath.startsWith('/') ? rawPath.substring(1) : rawPath;
        
        const libraryBase = "https://github.com/hak5/wifipineapplepager-payloads/tree/master/library";
        const fullReadmeUrl = `${libraryBase}/${cleanPath}`;
        // -------------------------------

        const authorUrl = `https://github.com/${script.author || ''}`;
        
        // We link to our local vote page, passing the issue number as a parameter
        const voteUrl = `site/vote.html?issue=${script.issue_number}`;

        article.innerHTML = `
            <header>
                <div class="meta-top">
                    <span class="category-badge">${script.category || 'General'}</span>
                    <span class="date-badge">${formatDate(script.last_updated)}</span>
                </div>
                
                <h2>${script.title}</h2>
                
                <div class="author-line">
                    by <a href="${authorUrl}" target="_blank" class="author-link">@${script.author}</a>
                </div>

                <div class="tags">${tagsHtml}</div>
            </header>
            
            <p class="description">${script.description}</p>
            
            <div class="actions">
                <a href="${fullReadmeUrl}" target="_blank" class="download-btn">
                    VIEW README
                </a>

                <a href="${voteUrl}" target="_blank" class="vote-btn" title="Login to GitHub to vote">
                    <span class="heart-icon">👍</span> 
                    <span class="vote-count">${script.votes || 0}</span>
                </a>
            </div>
        `;

        return article;
    }
});