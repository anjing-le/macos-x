import Foundation

/// One visible span of the rope. Coordinates are display-relative, not pixels.
/// The dragged photo follows the pointer; crossed neighbours take its old slot.
struct CaptureShelfLayout {
    private(set) var order: [UUID]
    private(set) var centers: [UUID:Double]
    let lower: Double
    let upper: Double

    init(items: [CaptureShelfStore.Item], display: String, width: CGFloat, cardWidth: CGFloat) {
        order=items.map(\.id); centers=[:]
        let span=max(1,Double(width)), margin=min(0.49,(Double(cardWidth)/2+12)/span)
        lower=margin; upper=1-margin
        for item in items {
            if let value=item.positions?[display] { centers[item.id]=min(upper,max(lower,value)) }
        }
        if centers.isEmpty {
            let first=(span-Double(max(0,items.count-1))*144)/2
            for (index,item) in items.enumerated() { centers[item.id]=min(upper,max(lower,(first+Double(index)*144)/span)) }
        } else {
            let slots=max(1,Int((span-28)/144))
            let candidates=(0..<slots).map { slots == 1 ? 0.5 : lower+(upper-lower)*Double($0)/Double(slots-1) }
            for item in items where centers[item.id] == nil {
                centers[item.id]=candidates.max { a,b in
                    centers.values.map { abs($0-a) }.min()! < centers.values.map { abs($0-b) }.min()!
                } ?? 0.5
            }
        }
        let initial=Dictionary(uniqueKeysWithValues:order.enumerated().map { ($0.element,$0.offset) })
        order.sort { centers[$0] == centers[$1] ? initial[$0]! < initial[$1]! : centers[$0]! < centers[$1]! }
    }
    func clamped(_ value:Double) -> Double { min(upper,max(lower,value)) }
    mutating func drag(_ id:UUID, to value:Double) -> Bool {
        guard var slot=centers[id], let initial=order.firstIndex(of:id) else { return false }
        let target=clamped(value)
        var changed=false, current=initial
        for _ in 0..<order.count {
            let candidates=order.filter { candidate in
                guard candidate != id, let center=centers[candidate] else { return false }
                return target > slot ? center > slot && center <= target : center < slot && center >= target
            }
            guard let next=candidates.min(by:{ abs(centers[$0]!-slot) < abs(centers[$1]!-slot) }),
                  let index=order.firstIndex(of:next) else { break }
            let center=centers[next]!
            centers[next]=slot; centers[id]=center
            order.swapAt(current,index); current=index; slot=center; changed=true
        }
        return changed
    }
    mutating func drop(_ id:UUID, at value:Double) {
        centers[id]=clamped(value)
        let previous=Dictionary(uniqueKeysWithValues:order.enumerated().map { ($0.element,$0.offset) })
        order.sort { centers[$0] == centers[$1] ? previous[$0]! < previous[$1]! : centers[$0]! < centers[$1]! }
    }
    mutating func swap(_ first:UUID,_ second:UUID) {
        guard let a=centers[first],let b=centers[second],let i=order.firstIndex(of:first),let j=order.firstIndex(of:second) else { return }
        centers[first]=b; centers[second]=a; order.swapAt(i,j)
    }
}
