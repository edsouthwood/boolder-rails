import { Controller } from "@hotwired/stimulus";
import { searchOffline } from "offline_areas";

// How long to wait for /search before falling back to the saved offline data. On the
// moor a phone can show signal while requests hang for tens of seconds.
const SEARCH_TIMEOUT_MS = 5000;

function debouncePromise(fn, time) {
  let timerId;
  return function (...args) {
    if (timerId) clearTimeout(timerId);
    return new Promise(resolve => {
      timerId = setTimeout(() => resolve(fn(...args)), time);
    });
  };
}

// Resolves to { results, offline }: the server's results, or — when it can't be
// reached — matches from the areas saved for offline use (offline_areas.js).
const debouncedSearch = debouncePromise(async (query, params = {}) => {
  if (!query) return null;
  if (navigator.onLine !== false) {
    try {
      const searchParams = new URLSearchParams({ query, ...params });
      const res = await fetch(`/search?${searchParams.toString()}`, { signal: AbortSignal.timeout(SEARCH_TIMEOUT_MS) });
      if (res.ok) return { results: await res.json(), offline: false };
    } catch (_) {}
  }
  if (!("caches" in window)) return { results: [], offline: true };
  return { results: await searchOffline(query, params.locale), offline: true };
}, 400);

function escapeHtml(text) {
  return String(text ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

export default class extends Controller {
  static targets = [
    "searchInput",
    "searchDropdown",
    "searchResults",
    "searchIcon",
    "spinnerIcon",
    "cancelButton",
    "clearButton",
    "searchModal",
    "offlineNote"
  ];

  static values = {
    locale: String,
    debug: Boolean,
    placeholder: String,
    clear: String,
    cancel: String,
    submit: String,
    showUnpublished: { type: Boolean, default: false },
    // { colors: [[hex, [grades]], ...], unknown: hex, outline: hex } — rendered by
    // ProblemsHelper#grade_colors_json so the site has one grade palette.
    gradeColors: Object
  };

  // Grade colouring, matching the problem lists, the topo circles and the map.
  gradeStyle(grade) {
    const palette = this.gradeColorsValue || {}
    const key = String(grade ?? "").trim().toLowerCase()
    const hit = (palette.colors || []).find(([, grades]) => grades.includes(key))
    const background = hit ? hit[0] : (palette.unknown || "rgb(80% 80% 80%)")
    const isWhite = background.toUpperCase() === "#FFFFFF"
    return {
      background,
      color: isWhite ? "#333" : "#FFF",
      // outline a white dot so it stays visible on the white dropdown
      shadow: isWhite ? `inset 0 0 0 1px ${palette.outline || "#888"}` : "none"
    }
  }

  connect() {
    this.searchInputTarget.value = "";
    this.locale = this.hasLocaleValue ? this.localeValue : "en";
    this.showUnpublished = this.showUnpublishedValue;
    this._activeDescendant = '';
    this.updatingResults = false;
  }

  get activeDescendant() {
    return this._activeDescendant;
  }

  set activeDescendant(value) {
    if (this._activeDescendant) {
      const prevElement = document.getElementById(this._activeDescendant);
      if (prevElement) {
        prevElement.classList.remove('bg-emerald-600/10');
        prevElement.setAttribute('aria-selected', 'false');
      }
    }

    this._activeDescendant = value;

    if (this._activeDescendant) {
      const newElement = document.getElementById(this._activeDescendant);
      if (newElement) {
        newElement.classList.add('bg-emerald-600/10');
        newElement.setAttribute('aria-selected', 'true');
      }
    }
  }

  async performSearch() {
    const query = this.searchInputTarget.value.trim();

    this.searchResultsTarget.classList.add('!text-gray-400', 'grayscale', 'filter');

    if (query.length) {
      this.searchIconTarget.classList.add("hidden");
      this.spinnerIconTarget.classList.remove("hidden");
      this.clearButtonTarget.classList.remove("hidden");
    }

    const response = await debouncedSearch(query,
      { locale: this.locale, ...(this.showUnpublished ? { show_unpublished: true } : {}) });

    this.searchResultsTarget.classList.remove('!text-gray-400', 'grayscale', 'filter');

    if (query.length === 0) {
      this.clearResults();
      return;
    }

    this.searchIconTarget.classList.remove("hidden");
    this.spinnerIconTarget.classList.add("hidden");

    this.updateResults(response.results, response.offline);
  }

  updateResults(results, offline = false) {
    this.searchResultsTarget.innerHTML = "";

    this.disableMouseEvents = true;

    results.forEach((item) => {
      const li = document.createElement("li");
      li.className = "select-none px-4 py-2";
      li.id = `option-${item.id}`;
      li.role = "option";
      li.tabIndex = "-1";
      li.setAttribute('aria-selected', 'false');

      li.innerHTML = this.renderItem(item);

      li.addEventListener("click", () => this.handleResultClick(item));
      li.addEventListener("mouseenter", () => this.handleMouseEnter(li));
      li.addEventListener("mouseleave", () => this.handleMouseLeave());

      this.searchResultsTarget.appendChild(li);
    });

    setTimeout(() => {
      this.disableMouseEvents = false;
    }, 100);

    if (this.hasOfflineNoteTarget) {
      this.offlineNoteTarget.textContent = results.length > 0
        ? "Offline — showing results from your saved areas"
        : "Offline — no matches in your saved areas";
      this.offlineNoteTarget.classList.toggle("hidden", !offline);
    }

    if (results.length > 0 || (offline && this.hasOfflineNoteTarget)) {
      this.searchDropdownTarget.classList.remove("hidden");
      this.searchInputTarget.setAttribute("aria-expanded", "true");
      this.searchInputTarget.setAttribute("aria-activedescendant", this.activeDescendant);
    } else {
      this.searchDropdownTarget.classList.add("hidden");
      this.searchInputTarget.setAttribute("aria-expanded", "false");
      this.searchInputTarget.setAttribute("aria-activedescendant", '');
    }
  }

  handleMouseEnter(li) {
    if (!this.disableMouseEvents) {
      this.activeDescendant = li.id;
    }
  }

  handleMouseLeave() {
    if (!this.disableMouseEvents) {
      this.activeDescendant = '';
    }
  }

  renderItem(item) {
    if (item.type === "Problem") {
      return `
        <div class="flex justify-between items-center">
          <div class="flex items-center">
            <span style="background: ${this.gradeStyle(item.grade).background}; color: ${this.gradeStyle(item.grade).color}; box-shadow: ${this.gradeStyle(item.grade).shadow}" class="rounded-full h-6 w-6 leading-6 inline-flex justify-center flex-shrink-0">
              ${escapeHtml(item.circuit_number) || "&nbsp;"}
            </span>
            <span class="ml-2">${escapeHtml(item.name)}</span>
            <span class="ml-2 text-gray-400">${escapeHtml(item.grade)}</span>
          </div>
          <span class="ml-2 text-gray-400 flex-shrink-0">${escapeHtml(item.area_name)}</span>
        </div>
      `;
    } else {
      return escapeHtml(item.name);
    }
  }

  handleResultClick(item) {
    const event = new CustomEvent(item.type === "Area" ? "gotoarea" : "gotoproblem", {
      detail: this.createDetail(item)
    });
    window.dispatchEvent(event);
    this.closeModal();
  }

  createDetail(item) {
    if (item.type === "Area") {
      return {
        id: item.id,
        name: item.name,
        path: item.path,
        south_west_lat: item.bounds.south_west.lat,
        south_west_lon: item.bounds.south_west.lng,
        north_east_lat: item.bounds.north_east.lat,
        north_east_lon: item.bounds.north_east.lng,
      };
    } else {
      return {
        id: item.id,
        name: item.name,
        grade: item.grade,
        path: item.path,
        lat: item.geolocation.lat,
        lon: item.geolocation.lng
      };
    }
  }

  handleKeydown(event) {
    const { key } = event;

    if (key === "ArrowDown" || key === "ArrowUp") {
      this.moveFocus(key === "ArrowDown");
      event.preventDefault();
    } else if (key === "Enter" && this.activeDescendant) {
      const selectedElement = document.getElementById(this.activeDescendant);
      selectedElement.click();
    } else if (key === "Escape") {
      this.closeModal();
    }
  }

  moveFocus(down) {
    const options = Array.from(this.searchResultsTarget.children);
    let currentIndex = options.findIndex(option => option.id === this.activeDescendant);

    if (down) {
      currentIndex = (currentIndex + 1) % options.length;
    } else {
      currentIndex = (currentIndex - 1 + options.length) % options.length;
    }

    this.activeDescendant = options[currentIndex].id;
    this.searchInputTarget.setAttribute("aria-activedescendant", this.activeDescendant);
  }

  openModal(event) {
    event.stopPropagation();
    const modal = this.searchModalTarget;
    modal.classList.remove("hidden");
    document.body.style.overflow = "hidden";
    this.searchInputTarget.focus();
    document.addEventListener("click", this.closeModal.bind(this));
    this.searchInputTarget.setAttribute("aria-expanded", "true");
  }

  closeModal(event) {
    const modal = this.searchModalTarget;
    const searchDropdown = this.searchDropdownTarget;

    if (!event || (!this.searchInputTarget.contains(event.target) && !searchDropdown.contains(event.target))) {
      modal.classList.add("hidden");
      document.body.style.overflow = "";
      document.removeEventListener("click", this.closeModal.bind(this));
      this.searchInputTarget.setAttribute("aria-expanded", "false");
    }
  }

  clearSearch(event) {
    event.stopPropagation();
    this.searchInputTarget.value = "";
    this.searchInputTarget.focus();
    this.searchDropdownTarget.classList.add("hidden");
    this.clearButtonTarget.classList.add("hidden");
    this.searchInputTarget.setAttribute("aria-expanded", "false");
  }

  clearResults() {
    this.searchResultsTarget.innerHTML = "";
    this.searchDropdownTarget.classList.add("hidden");
    this.spinnerIconTarget.classList.add("hidden");
    this.clearButtonTarget.classList.add("hidden");
    this.searchIconTarget.classList.remove("hidden");
    this.activeDescendant = '';
    this.searchInputTarget.setAttribute("aria-expanded", "false");
    this.searchInputTarget.setAttribute("aria-activedescendant", '');
  }
}
