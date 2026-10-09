export function createPageScrollLimiter({ pages, pageIndex, offset, setOffset }) {
    let bounds = null;
    const reset = () => { bounds = null; };
    return {
        reset,
        begin(touchCount) {
            reset();
            if (touchCount !== 1) return;
            const elements = pages();
            const index = pageIndex();
            const current = elements[index];
            if (!current) return;
            const start = offset();
            const top = current.getBoundingClientRect().top;
            const first = elements[Math.max(0, index - 4)];
            const last = elements[Math.min(elements.length - 1, index + 4)];
            bounds = {
                minimum: Math.max(0, start + first.getBoundingClientRect().top - top),
                maximum: Math.max(0, start + last.getBoundingClientRect().top - top),
            };
        },
        constrain() {
            if (!bounds) return false;
            const current = offset();
            const target = Math.max(bounds.minimum, Math.min(bounds.maximum, current));
            if (target === current) return false;
            setOffset(target);
            return true;
        },
    };
}