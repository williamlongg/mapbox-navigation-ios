import MapboxDirections
import MapboxCoreNavigation

@objc public protocol InstructionsCardCollectionDelegate: InstructionsCardContainerViewDelegate {
    /**
     Called when previewing the steps on the current route.
     
     Implementing this method will allow developers to move focus to the maneuver that corresponds to the step currently previewed.
     - parameter instructionsCardCollection: The instructions card collection instance.
     - parameter step: The step for the maneuver instruction in preview.
     */
    @objc(instructionsCardCollection:previewFor:)
    func instructionsCardCollection(_ instructionsCardCollection: InstructionsCardCollection, previewFor step: RouteStep)
    
    /**
     Offers the delegate the opportunity to customize the size of a prototype collection view cell per the associated trait collection.
     
     - parameter instructionsCardCollection: The instructions card collection instance.
     - parameter cardSizeForTraitcollection: The trait collection associated to the current container view controller.
     - returns: The preferred size of the cards for each cell in the instructions card collection.
     */
    @objc(instructionsCardCollection:cardSizeForTraitcollection:)
    optional func instructionsCardCollection(_ instructionsCardCollection: InstructionsCardCollection, cardSizeForTraitcollection: UITraitCollection) -> CGSize
}

open class InstructionsCardCollection: UIViewController {
    typealias InstructionsCardCollectionLayout = UICollectionViewFlowLayout
    
    var routeProgress: RouteProgress?
    var cardSize: CGSize = .zero
    var cardStyle: DayInstructionsCardStyle = DayInstructionsCardStyle()
    
    var instructionCollectionView: UICollectionView!
    var instructionsCardLayout: InstructionsCardCollectionLayout!
    
    public private(set) var isInPreview = false
    private var currentStepIndex: Int?
    
    var steps: [RouteStep]? {
        guard let stepIndex = routeProgress?.currentLegProgress.stepIndex, let steps = routeProgress?.currentLeg.steps else { return nil }
        var mutatedSteps = steps
        if mutatedSteps.count > 1 {
            mutatedSteps = Array(mutatedSteps.suffix(from: stepIndex))
            mutatedSteps.removeLast()
        }
        return mutatedSteps
    }
    
    var distancesFromCurrentLocationToManeuver: [CLLocationDistance]? {
        guard let progress = routeProgress, let steps = steps else { return nil }
        let distanceRemaining = progress.currentLegProgress.currentStepProgress.distanceRemaining
        let distanceBetweenSteps = [distanceRemaining] + progress.remainingSteps.map {$0.distance}
        
        let distancesFromCurrentLocationToManeuver: [CLLocationDistance] = steps.enumerated().map { (index, _) in
            let safeIndex = index < distanceBetweenSteps.endIndex ? index : distanceBetweenSteps.endIndex - 1
            let cardDistance = distanceBetweenSteps[0...safeIndex].reduce(0, +)
            return cardDistance > 5 ? cardDistance : 0
        }
        return distancesFromCurrentLocationToManeuver
    }
    
    /**
     The InstructionsCardCollection delegate.
     */
    @objc public weak var cardCollectionDelegate: InstructionsCardCollectionDelegate?
    
    fileprivate var contentOffsetBeforeSwipe = CGPoint(x: 0, y: 0)
    fileprivate var indexBeforeSwipe = IndexPath(row: 0, section: 0)
    fileprivate var previewIndexPath = IndexPath(row: 0, section: 0)
    fileprivate var isSnapAndRemove = false
    fileprivate let cardCollectionCellIdentifier = "InstructionsCardCollectionCellID"
    fileprivate let collectionViewFlowLayoutMinimumSpacingDefault: CGFloat = 10.0
    fileprivate let collectionViewPadding: CGFloat = 8.0
    
    lazy open var topPaddingView: TopBannerView =  {
        let view: TopBannerView = .forAutoLayout()
        return view
    }()
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        /* TODO: Identify the traitCollections to define the width of the cards */
        if let customSize = cardCollectionDelegate?.instructionsCardCollection?(self, cardSizeForTraitcollection: traitCollection) {
            cardSize = customSize
        } else {
            cardSize = CGSize(width: Int(floor(view.frame.size.width * 0.82)), height: 200)
        }
        
        /* TODO: Custom dataSource */
        
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        
        instructionsCardLayout = InstructionsCardCollectionLayout()
        instructionsCardLayout.scrollDirection = .horizontal
        instructionsCardLayout.itemSize = cardSize
        
        instructionCollectionView = UICollectionView(frame: .zero, collectionViewLayout: instructionsCardLayout)
        instructionCollectionView.register(InstructionsCardCell.self, forCellWithReuseIdentifier: cardCollectionCellIdentifier)
        instructionCollectionView.contentInset = UIEdgeInsets(top: 0, left: collectionViewPadding, bottom: 0, right: collectionViewPadding)
        instructionCollectionView.contentOffset = CGPoint(x: -collectionViewPadding, y: 0.0)
        instructionCollectionView.dataSource = self
        instructionCollectionView.delegate = self
        
        instructionCollectionView.showsVerticalScrollIndicator = false
        instructionCollectionView.showsHorizontalScrollIndicator = false
        instructionCollectionView.backgroundColor = .clear
        instructionCollectionView.isPagingEnabled = true
        instructionCollectionView.translatesAutoresizingMaskIntoConstraints = false
        
        addSubviews()
        setConstraints()
        
        view.clipsToBounds = false
        topPaddingView.backgroundColor = .clear
    }
    
    func addSubviews() {
        [topPaddingView, instructionCollectionView].forEach(view.addSubview(_:))
    }
    
    func setConstraints() {
        let topPaddingConstraints: [NSLayoutConstraint] = [
            topPaddingView.topAnchor.constraint(equalTo: view.topAnchor),
            topPaddingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topPaddingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topPaddingView.bottomAnchor.constraint(equalTo: view.safeTopAnchor),
            ]
        
        NSLayoutConstraint.activate(topPaddingConstraints)
        
        let instructionCollectionViewContraints: [NSLayoutConstraint] = [
            instructionCollectionView.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor),
            instructionCollectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            instructionCollectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            instructionCollectionView.heightAnchor.constraint(equalToConstant: cardSize.height),
            instructionCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        
        NSLayoutConstraint.activate(instructionCollectionViewContraints)
    }
    
    func reloadDataSource() {
        if isInPreview {
            if previewIndexPath.row < steps!.endIndex - 1 {
                updateVisibleInstructionCards(at: [previewIndexPath], previewEnabled: true)
            } else {
                instructionCollectionView.reloadData()
            }
        } else {
            if currentStepIndex == nil, let progress = routeProgress {
                currentStepIndex = progress.currentLegProgress.stepIndex
                instructionCollectionView.reloadData()
            } else if let progress = routeProgress, let stepIndex = currentStepIndex, stepIndex != progress.currentLegProgress.stepIndex {
                currentStepIndex = progress.currentLegProgress.stepIndex
                instructionCollectionView.reloadData()
            } else {
                updateVisibleInstructionCards(at: instructionCollectionView.indexPathsForVisibleItems)
            }
        }
    }
    
    func updateVisibleInstructionCards(at indexPaths: [IndexPath], previewEnabled: Bool = false) {
        guard let distances = distancesFromCurrentLocationToManeuver else { return }
        for index in indexPaths.startIndex..<indexPaths.endIndex {
            let indexPath = indexPaths[index]
            if let container = instructionContainerView(at: indexPath), indexPath.row < distances.endIndex {
                let distance = distances[indexPath.row]
                container.updateInstructionCard(distance: distance, previewEnabled: previewEnabled)
            }
        }
    }
    
    func snapToIndexPath(_ indexPath: IndexPath) {
        let itemCount = collectionView(instructionCollectionView, numberOfItemsInSection: 0)
        guard itemCount >= 0 && indexPath.row < itemCount else { return }
        instructionsCardLayout.collectionView?.scrollToItem(at: indexPath, at: .left, animated: true)
    }
    
    public func stopPreview() {
        guard isInPreview else { return }
        instructionCollectionView.scrollToItem(at: IndexPath(row: 0, section: 0), at: .left, animated: false)
        isInPreview = false
    }
    
    fileprivate func instructionContainerView(at indexPath: IndexPath) -> InstructionsCardContainerView? {
        guard let cell = instructionCollectionView.cellForItem(at: indexPath),
            cell.subviews.count > 1 else {
                return nil
        }
        
        return cell.subviews[1] as? InstructionsCardContainerView
    }
    
    fileprivate func calculateNeededSpace(count: Int) -> CGSize {
        let cardSize = instructionsCardLayout.itemSize
        return CGSize(width: (cardSize.width + 10) * CGFloat(count), height: cardSize.height)
    }
    
    fileprivate func snappedIndexPath() -> IndexPath {
        guard let collectionView = instructionsCardLayout.collectionView, let itemCount = steps?.count else {
            return IndexPath(row: 0, section: 0)
        }
        
        let estimatedIndex = Int(round((collectionView.contentOffset.x + collectionView.contentInset.left) / (cardSize.width + collectionViewFlowLayoutMinimumSpacingDefault)))
        let indexInBounds = max(0, min(itemCount - 1, estimatedIndex))
        
        return IndexPath(row: indexInBounds, section: 0)
    }
    
    fileprivate func scrollTargetIndexPath(for scrollView: UIScrollView, with velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) -> IndexPath {
        targetContentOffset.pointee = scrollView.contentOffset
        
        let itemCount = steps?.count ?? 0
        let velocityThreshold: CGFloat = 0.4
        
        let hasVelocityToSlideToNext = indexBeforeSwipe.row + 1 < itemCount && velocity.x > velocityThreshold
        let hasVelocityToSlidePrev = indexBeforeSwipe.row - 1 >= 0 && velocity.x < -velocityThreshold
        let didSwipe = hasVelocityToSlideToNext || hasVelocityToSlidePrev
        
        let scrollTargetIndexPath: IndexPath!
        
        if didSwipe {
            if hasVelocityToSlideToNext {
                scrollTargetIndexPath = IndexPath(row: indexBeforeSwipe.row + 1, section: 0)
            } else {
                scrollTargetIndexPath = IndexPath(row: indexBeforeSwipe.row - 1, section: 0)
            }
        } else {
            if scrollView.contentOffset.x - contentOffsetBeforeSwipe.x < -cardSize.width / 2 {
                scrollTargetIndexPath = IndexPath(row: indexBeforeSwipe.row - 1, section: 0)
            } else if scrollView.contentOffset.x - contentOffsetBeforeSwipe.x > cardSize.width / 2 {
                scrollTargetIndexPath = IndexPath(row: indexBeforeSwipe.row + 1, section: 0)
            } else {
                scrollTargetIndexPath = indexBeforeSwipe
            }
        }
        
        return scrollTargetIndexPath
    }
}

extension InstructionsCardCollection: UICollectionViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        indexBeforeSwipe = snappedIndexPath()
        contentOffsetBeforeSwipe = scrollView.contentOffset
    }
    
    public func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let indexPath = scrollTargetIndexPath(for: scrollView, with: velocity, targetContentOffset: targetContentOffset)
        snapToIndexPath(indexPath)
        
        isInPreview = true
        let previewIndex = indexPath.row
        previewIndexPath = indexPath
        
        if isInPreview, let steps = steps, previewIndex < steps.endIndex {
            let previewStep = steps[previewIndex]
            cardCollectionDelegate?.instructionsCardCollection(self, previewFor: previewStep)
        }
    }
}

extension InstructionsCardCollection: UICollectionViewDataSource {
    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return steps?.count ?? 0
    }
    
    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: cardCollectionCellIdentifier, for: indexPath) as! InstructionsCardCell
        
        guard let steps = steps, indexPath.row < steps.endIndex, let distances = distancesFromCurrentLocationToManeuver, indexPath.row < distances.endIndex else {
            return cell
        }

        cell.style = cardStyle
        cell.container.delegate = self
        
        let step = steps[indexPath.row]
        let distance = distances[indexPath.row]
        cell.configure(for: step, distance: distance, previewEnabled: isInPreview)
        
        return cell
    }
}

extension InstructionsCardCollection: UICollectionViewDelegateFlowLayout {
    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return cardSize
    }
}

extension InstructionsCardCollection: NavigationComponent {
    public func navigationService(_ service: NavigationService, didUpdate progress: RouteProgress, with location: CLLocation, rawLocation: CLLocation) {
        routeProgress = progress
        reloadDataSource()
    }
    
    public func navigationService(_ service: NavigationService, didPassVisualInstructionPoint instruction: VisualInstructionBanner, routeProgress: RouteProgress) {
        self.routeProgress = routeProgress
        reloadDataSource()
    }
}

extension InstructionsCardCollection: InstructionsCardContainerViewDelegate {
    
    public func primaryLabel(_ primaryLabel: InstructionLabel, willPresent instruction: VisualInstruction, as presented: NSAttributedString) -> NSAttributedString? {
        return cardCollectionDelegate?.primaryLabel?(primaryLabel, willPresent: instruction, as: presented)
    }
    
    public func secondaryLabel(_ secondaryLabel: InstructionLabel, willPresent instruction: VisualInstruction, as presented: NSAttributedString) -> NSAttributedString? {
        return cardCollectionDelegate?.secondaryLabel?(secondaryLabel, willPresent: instruction, as: presented)
    }
}

extension InstructionsCardCollection: NavigationMapInteractionObserver {
    public func navigationViewController(didCenterOn location: CLLocation) {
        stopPreview()
    }
}
