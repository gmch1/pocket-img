package backend

import "sync"

// galleryEvents keeps subscriptions isolated by owner. Notifications carry no
// image metadata and use a one-item buffer so bursts naturally coalesce.
type galleryEvents struct {
	mu          sync.Mutex
	subscribers map[string]map[chan struct{}]struct{}
}

func newGalleryEvents() *galleryEvents {
	return &galleryEvents{subscribers: make(map[string]map[chan struct{}]struct{})}
}

func (events *galleryEvents) subscribe(ownerID string) (<-chan struct{}, func()) {
	updates := make(chan struct{}, 1)
	events.mu.Lock()
	ownerSubscribers := events.subscribers[ownerID]
	if ownerSubscribers == nil {
		ownerSubscribers = make(map[chan struct{}]struct{})
		events.subscribers[ownerID] = ownerSubscribers
	}
	ownerSubscribers[updates] = struct{}{}
	events.mu.Unlock()

	var once sync.Once
	return updates, func() {
		once.Do(func() {
			events.mu.Lock()
			delete(ownerSubscribers, updates)
			if len(ownerSubscribers) == 0 {
				delete(events.subscribers, ownerID)
			}
			events.mu.Unlock()
		})
	}
}

func (events *galleryEvents) notify(ownerID string) {
	events.mu.Lock()
	defer events.mu.Unlock()
	for updates := range events.subscribers[ownerID] {
		select {
		case updates <- struct{}{}:
		default:
		}
	}
}
